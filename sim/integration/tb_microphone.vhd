library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;

-- Real 100 MHz/2 MHz/16 kHz rates; only the startup wait is accelerated.
-- The microphone drives during the low half-cycle and releases after the
-- rising edge. The oracle convolves its intended bits, then models DC removal.
entity tb_microphone is end entity;
architecture sim of tb_microphone is
    constant R : positive := 125;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal mic_data : std_logic := 'Z';
    signal mic_clock, lrsel, capture_ready, bit_value, bit_valid : std_logic;
    signal raw_pcm, pcm : signed(7 downto 0);
    signal raw_valid, filter_ready, cic_clipped, valid, dc_clipped : std_logic;
    signal source_bit : std_logic := '0';
    signal mode : natural range 0 to 2 := 0;
    signal outputs, clip_count : natural := 0;
    type integers_t is array(natural range <>) of integer;
    type flags_t is array(natural range <>) of boolean;
    function triangle(n : integer) return integer is
    begin if n < 0 then return 0; end if; return (n+1)*(n+2)/2; end function;
    function coefficient(k : natural) return integer is
    begin return triangle(k)-3*triangle(k-R)+3*triangle(k-2*R)-triangle(k-3*R); end function;
    function floor_div(a : integer; b : positive) return integer is
    begin if a < 0 then return -((-a+b-1)/b); end if; return a/b; end function;
    function clip(x : integer) return integer is
    begin if x > 127 then return 127; elsif x < -128 then return -128; end if; return x; end function;
begin
    clk <= not clk after 5 ns;
    capture : entity work.pdm_capture
        generic map (G_HALF_PERIOD_CYCLES => 25, G_WARMUP_CYCLES => 200)
        port map (clk, rst, mic_data, mic_clock, lrsel, capture_ready, bit_value, bit_valid);
    decimator : entity work.pdm_decimator generic map (G_DECIMATION => R, G_SHIFT => 12)
        port map (clk, rst, bit_value, bit_valid, raw_pcm, raw_valid, filter_ready, cic_clipped);
    blocker : entity work.dc_blocker
        port map (clk, rst, raw_valid, raw_pcm, pcm, valid, dc_clipped);

    microphone : process(mic_clock)
        variable count, density_accum, target : integer := 0;
        variable b : std_logic;
    begin
        if falling_edge(mic_clock) then
            if mode = 1 then b := '1';
            elsif mode = 2 then
                if count mod 2 = 0 then b := '0'; else b := '1'; end if;
            else
                target := integer(17084.0+2600.0*sin(2.0*MATH_PI*real(count)/2000.0));
                density_accum := density_accum+target;
                if density_accum >= 32768 then b := '1'; density_accum := density_accum-32768;
                else b := '0'; end if;
            end if;
            source_bit <= b;
            mic_data <= b after 60 ns;
            count := count+1;
        elsif rising_edge(mic_clock) then
            mic_data <= 'Z' after 5 ns;
        end if;
    end process;

    scoreboard : process
        variable history : integers_t(0 to 3*R-3) := (others => 0);
        variable expected : integers_t(0 to 8) := (others => 0);
        variable present : flags_t(0 to 8) := (others => false);
        variable expected_clip : flags_t(0 to 8) := (others => false);
        variable count, discarded, previous_x, state, last : integer := 0;
        variable new_value, sum, x, leakage, rounded : integer;
        variable new_present, new_clip : boolean;
        variable last_bit_time, last_output_time : time := 0 ns;
    begin
        wait until rising_edge(clk);
        new_present := false; new_clip := false; new_value := 0;
        if rst = '1' then
            history := (others => 0); expected := (others => 0);
            present := (others => false); expected_clip := (others => false);
            count := 0; discarded := 0; previous_x := 0; state := 0; last := 0;
            last_bit_time := 0 ns; last_output_time := 0 ns;
            outputs <= 0; clip_count <= 0;
        else
            if raw_valid = '1' and cic_clipped = '1' then clip_count <= clip_count+1; end if;
            if bit_valid = '1' then
                assert capture_ready = '1' and lrsel = '0' and bit_value = source_bit
                    report "Capture disagrees with microphone model" severity failure;
                if last_bit_time /= 0 ns then
                    assert now-last_bit_time = 500 ns report "PDM sample cadence changed" severity failure;
                end if;
                last_bit_time := now;
                for i in history'high downto 1 loop history(i) := history(i-1); end loop;
                if source_bit = '1' then history(0) := 1; else history(0) := -1; end if;
                if count = R-1 then
                    count := 0;
                    if discarded < 2 then discarded := discarded+1;
                    else
                        sum := 0;
                        for k in history'range loop sum := sum+history(k)*coefficient(k); end loop;
                        x := clip(floor_div(sum+2048, 4096));
                        if state > 0 then leakage := (state+255)/256;
                        elsif state < 0 then leakage := -((-state+255)/256);
                        else leakage := 0; end if;
                        state := state+(x-previous_x)*256-leakage; previous_x := x;
                        if state < 0 then rounded := -((-state+128)/256);
                        else rounded := (state+128)/256; end if;
                        new_value := clip(rounded); new_present := true;
                        new_clip := rounded > 127 or rounded < -128;
                    end if;
                else count := count+1; end if;
            end if;
        end if;
        wait for 1 ns;
        if rst = '1' then
            assert valid = '0' and raw_valid = '0' and filter_ready = '0' and pcm = 0 severity failure;
        else
            if present(8) then
                assert valid = '1' and to_integer(pcm) = expected(8)
                    report "Complete microphone path data/latency mismatch" severity failure;
                assert (dc_clipped = '1') = expected_clip(8) severity failure;
                assert filter_ready = '1' severity failure;
                if last_output_time /= 0 ns then
                    assert now-last_output_time = 62500 ns
                        report "PCM sample cadence is not 16 kHz" severity failure;
                end if;
                last_output_time := now; outputs <= outputs+1; last := expected(8);
            else
                assert valid = '0' and dc_clipped = '0' and to_integer(pcm) = last
                    report "Unscheduled microphone output" severity failure;
            end if;
            for k in 8 downto 1 loop
                expected(k) := expected(k-1); present(k) := present(k-1);
                expected_clip(k) := expected_clip(k-1);
            end loop;
            expected(0) := new_value; present(0) := new_present; expected_clip(0) := new_clip;
        end if;
    end process;

    stimulus : process
    begin
        wait for 100 ns; wait until falling_edge(clk); rst <= '0';
        wait until outputs = 80;
        mode <= 1;
        wait until outputs = 90;
        assert clip_count > 0 report "Microphone clipping indicator was never asserted" severity failure;
        -- Reset acquisition and filters while a capture transaction is pending.
        wait until rising_edge(mic_clock); wait until falling_edge(clk); rst <= '1';
        wait for 100 ns; wait until falling_edge(clk); rst <= '0'; mode <= 2;
        wait until outputs = 24;
        assert pcm = 0 and clip_count = 0
            report "Silence or reset invalidation failed through microphone chain" severity failure;
        report "PASS: tb_microphone" severity note; stop; wait;
    end process;
    process begin wait for 20 ms; assert false report "tb_microphone timeout" severity failure; end process;
end architecture;
