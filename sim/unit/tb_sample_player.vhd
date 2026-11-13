-- Stage 04: self-checking RAM/player/interpolation testbench.
-- VHDL-2008 simulation only (std.env.stop).
-- Uses the production one-cycle synchronous-read sample RAM.
-- Fast 8-sample loop with deliberately irregular PCM, including extremes.
-- Tests nearest vs linear, all Stage 03 rates, 0.25/1.25 fractional
-- rates, wrap neighbor last->first, live mode/step changes, pause/reset.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_sample_player is
end entity;

architecture sim of tb_sample_player is
    constant PERIOD       : time := 10 ns;
    constant ADDR_BITS    : positive := 4;
    constant FRAC_BITS    : positive := 8;
    constant SAMPLE_COUNT : positive := 8;
    constant SCALE        : positive := 2**FRAC_BITS;
    constant LOOP_Q       : positive := SAMPLE_COUNT*SCALE;

    type values_t is array (0 to SAMPLE_COUNT-1) of integer;
    constant SAMPLES : values_t := (-128, 127, -81, 73, -5, 6, 100, -99);

    signal clk       : std_logic := '0';
    signal rst       : std_logic := '1';
    signal play      : std_logic := '0';
    signal tick      : std_logic := '0';
    signal step      : unsigned(FRAC_BITS+1 downto 0) := (others => '0');
    signal linear    : std_logic := '0';
    signal rd_addr   : unsigned(ADDR_BITS-1 downto 0);
    signal rd_data   : signed(7 downto 0);
    signal frac      : unsigned(FRAC_BITS-1 downto 0);
    signal pcm       : signed(7 downto 0);
    signal pcm_valid : std_logic;
    signal ready     : std_logic;
    signal wr_en     : std_logic := '0';
    signal wr_addr   : unsigned(ADDR_BITS-1 downto 0) := (others => '0');
    signal wr_data   : signed(7 downto 0) := (others => '0');
    signal sample_length : unsigned(ADDR_BITS downto 0) := to_unsigned(SAMPLE_COUNT, ADDR_BITS+1);

    function reference_sample(phase_q : integer; interpolated : boolean;
                              active_length : positive)
        return integer is
        variable idx       : integer;
        variable frac_q    : integer;
        variable diff      : integer;
        variable weighted  : integer;
        variable increment : integer;
        variable result    : integer;
    begin
        idx := phase_q / SCALE;
        frac_q := phase_q mod SCALE;
        if not interpolated then
            return SAMPLES(idx);
        end if;

        diff := SAMPLES((idx+1) mod active_length) - SAMPLES(idx);
        weighted := diff * frac_q;
        if weighted >= 0 then
            increment := (weighted + SCALE/2) / SCALE;
        else
            increment := -((-weighted + SCALE/2) / SCALE);
        end if;
        result := SAMPLES(idx) + increment;
        if result > 127 then
            return 127;
        elsif result < -128 then
            return -128;
        else
            return result;
        end if;
    end function;
begin
    clk <= not clk after PERIOD/2;

    watchdog : process
    begin
        wait for 1 ms;
        assert false report "tb_sample_player timeout" severity failure;
    end process;

    u_memory : entity work.sample_ram
        generic map (
            ADDR_BITS => ADDR_BITS,
            INIT_FILE => ""
        )
        port map (
            clk_i => clk, wr_en_i => wr_en,
            wr_addr_i => wr_addr, wr_data_i => wr_data,
            rd_addr_i => rd_addr, rd_data_o => rd_data
        );

    u_player : entity work.sample_player
        generic map (
            ADDR_BITS => ADDR_BITS,
            FRAC_BITS => FRAC_BITS,
            SAMPLE_COUNT => SAMPLE_COUNT
        )
        port map (
            clk_i => clk, rst_i => rst,
            play_i => play, sample_tick_i => tick,
            step_i => step, linear_mode_i => linear,
            rd_addr_o => rd_addr, rd_data_i => rd_data,
            phase_frac_o => frac, pcm_o => pcm,
            pcm_valid_o => pcm_valid, ready_o => ready,
            sample_length_i => sample_length
        );

    stimulus : process
        variable phase_model : integer := 0;

        procedure restart_player is
        begin
            wait until falling_edge(clk);
            rst  <= '1';
            play <= '0';
            tick <= '0';
            wait until rising_edge(clk);
            wait for 1 ns;
            assert pcm = to_signed(0,8) and pcm_valid = '0'
                report "sample_player reset did not silence output" severity failure;
            assert to_integer(frac)=0 and to_integer(rd_addr)=0
                report "sample_player reset did not zero phase/address" severity failure;
            wait until falling_edge(clk);
            rst  <= '0';
            play <= '1';
            -- Real board has 6250 clocks; prefetch + 3 pipeline stages
            -- need only a handful. Use 12 to give comfortable margin.
            for i in 1 to 12 loop
                wait until rising_edge(clk);
                wait for 1 ns;
            end loop;
            assert ready = '1'
                report "sample_player did not prefetch the initial PCM pair" severity failure;
        end procedure;

        procedure playback_tick(
            variable phase_q    : inout integer;
            constant step_q     : in integer;
            constant do_linear  : in boolean
        ) is
            variable expected_value : integer;
        begin
            expected_value := reference_sample(phase_q, do_linear, to_integer(sample_length));
            wait until falling_edge(clk);
            assert ready = '1'
                report "Player not ready before audio tick" severity failure;
            step <= to_unsigned(step_q, step'length);
            if do_linear then
                linear <= '1';
            else
                linear <= '0';
            end if;
            tick <= '1';

            wait until rising_edge(clk);
            wait for 1 ns;
            assert pcm_valid = '1'
                report "Missing PCM valid pulse" severity failure;
            assert to_integer(pcm) = expected_value
                report "PCM mismatch: phase=" & integer'image(phase_q) &
                       " expected=" & integer'image(expected_value) &
                       " got=" & integer'image(to_integer(pcm))
                severity failure;

            phase_q := (phase_q + step_q) mod (to_integer(sample_length)*SCALE);
            assert to_integer(rd_addr) = phase_q / SCALE and
                   to_integer(frac) = phase_q mod SCALE
                report "Phase did not advance by requested fixed-point step"
                severity failure;

            wait until falling_edge(clk);
            tick <= '0';
            for i in 1 to 12 loop
                wait until rising_edge(clk);
                wait for 1 ns;
                assert pcm_valid = '0'
                    report "PCM valid must be one cycle long" severity failure;
            end loop;
            assert ready = '1'
                report "Player failed to prefetch next pair" severity failure;
        end procedure;

        procedure test_rate(
            constant step_q : in integer;
            constant count  : in positive;
            constant interpolation_enabled : in boolean;
            constant description : in string
        ) is
        begin
            restart_player;
            phase_model := 0;
            for i in 1 to count loop
                playback_tick(phase_model, step_q, interpolation_enabled);
            end loop;
            report "PASS: " & description severity note;
        end procedure;
    begin
        -- Initialization through the production RAM write port.
        for i in SAMPLES'range loop
            wait until falling_edge(clk);
            wr_en   <= '1';
            wr_addr <= to_unsigned(i,ADDR_BITS);
            wr_data <= to_signed(SAMPLES(i),8);
        end loop;
        wait until falling_edge(clk);
        wr_en <= '0';
        report "Test PCM RAM initialized" severity note;

        test_rate(SCALE/2,    20, false, "0.5x nearest neighbor");
        test_rate(SCALE/2,    20, true,  "0.5x linear interpolation");
        test_rate(SCALE,      12, true,  "1x exact stored PCM samples");
        test_rate(3*SCALE/2,  20, true,  "1.5x fractional interpolation");
        test_rate(2*SCALE,    12, true,  "2x skipped-sample interpolation");
        test_rate(SCALE/4,    40, true,  "0.25x with quarter fractions and rounding");
        test_rate(5*SCALE/4,  30, true,  "1.25x multiple fractions and wrap");
        report "PASS: last-to-first sample interpolation across loop" severity note;

        -- Change interpolation mode without changing phase.
        restart_player;
        phase_model := 0;
        playback_tick(phase_model, SCALE/2, false); -- advance to phase 0.5
        playback_tick(phase_model, 0, false);       -- same phase, nearest
        playback_tick(phase_model, 0, true);        -- same phase, linear
        playback_tick(phase_model, 0, false);       -- switch back
        report "PASS: live nearest/linear mode switching" severity note;

        -- Change pitch without resetting the phase accumulator.
        playback_tick(phase_model, 3*SCALE/2, true);
        playback_tick(phase_model, SCALE/4, true);
        playback_tick(phase_model, 5*SCALE/4, true);
        report "PASS: live pitch changes with interpolation" severity note;

        -- Pause stops phase and immediately drives digital silence.
        wait until falling_edge(clk);
        play <= '0';
        tick <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert pcm = to_signed(0,8) and pcm_valid = '0'
            report "Pause must mute and suppress PCM valid" severity failure;
        assert to_integer(frac) = phase_model mod SCALE
            report "Pause changed fractional phase" severity failure;
        wait until falling_edge(clk);
        tick <= '0';
        play <= '1';
        playback_tick(phase_model, SCALE/2, true);
        report "PASS: pause/resume without phase drift" severity note;

        -- A second tick while prefetching is rejected, without phase advance.
        restart_player;
        wait until falling_edge(clk);
        step <= to_unsigned(SCALE/2, step'length);
        tick <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert pcm_valid = '1' and to_integer(pcm) = SAMPLES(0)
            report "first tick after prefetch was not accepted" severity failure;
        assert ready = '0' and to_integer(frac) = SCALE/2 severity failure;
        -- Keep tick high for the very next edge, which is deliberately busy.
        wait until rising_edge(clk);
        wait for 1 ns;
        assert pcm_valid = '0' and to_integer(frac) = SCALE/2
            report "busy player accepted a tick or advanced phase" severity failure;
        wait until falling_edge(clk);
        tick <= '0';
        for i in 1 to 12 loop
            wait until rising_edge(clk);
            wait for 1 ns;
        end loop;
        phase_model := SCALE/2;
        playback_tick(phase_model, SCALE/2, true);
        report "PASS: busy tick rejected without phase drift" severity note;

        restart_player;
        report "PASS: explicit reset" severity note;
        phase_model := 0;
        -- A runtime clip-length change flushes prefetched operands even when
        -- the caller does not assert reset. No old clip sample may leak.
        playback_tick(phase_model, SCALE, true);
        wait until falling_edge(clk); sample_length <= to_unsigned(4, ADDR_BITS+1);
        wait for 1 ns;
        assert ready = '0' report "Length change did not invalidate ready" severity failure;
        for i in 1 to 10 loop wait until rising_edge(clk); wait for 1 ns; end loop;
        assert ready = '1' and frac = 0 severity failure;
        phase_model := 0;
        for i in 1 to 20 loop playback_tick(phase_model, 3*SCALE+SCALE/2, true); end loop;
        wait until falling_edge(clk); sample_length <= (others => '0'); tick <= '1';
        for i in 1 to 12 loop
            wait until rising_edge(clk); wait for 1 ns;
            assert ready = '0' and pcm_valid = '0' and pcm = 0
                report "Invalid clip length produced audio" severity failure;
        end loop;
        report "PASS: tb_sample_player" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
