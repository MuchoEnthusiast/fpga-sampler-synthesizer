-- A real recorder/RAM/player chain: no initialized sample or modeled RAM.
-- Check arbitrary committed clip lengths, the final write, fractional loop
-- boundaries, minimal legal tick spacing, re-recording and invalid clips.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_record_playback is end entity;
architecture sim of tb_record_playback is
    constant CAPACITY : positive := 12;
    constant SCALE : positive := 256;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal rec_start, rec_stop, input_valid, tick : std_logic := '0';
    signal input_data, write_data, read_data, pcm : signed(7 downto 0) := (others => '0');
    signal write_enable, recording, clip_ready, done, player_ready, output_valid : std_logic;
    signal write_addr, read_addr : unsigned(3 downto 0);
    signal length, count : unsigned(4 downto 0);
    signal fraction : unsigned(7 downto 0);
    signal step : unsigned(9 downto 0) := to_unsigned(256, 10);
    signal linear : std_logic := '1';
    signal player_rst : std_logic;
begin
    clk <= not clk after 5 ns;
    u_record : entity work.record_controller
        generic map (ADDR_BITS => 4, MAX_SAMPLES => CAPACITY)
        port map (clk, rst, rec_start, rec_stop, input_valid, input_data,
                  write_enable, write_addr, write_data, recording, clip_ready, done, length, count);
    u_ram : entity work.sample_ram
        generic map (ADDR_BITS => 4, INIT_FILE => "")
        port map (clk, write_enable, write_addr, write_data, read_addr, read_data);
    player_rst <= rst or recording or not clip_ready or rec_start;
    u_player : entity work.sample_player
        generic map (ADDR_BITS => 4, FRAC_BITS => 8, SAMPLE_COUNT => CAPACITY)
        port map (clk, player_rst, '1', tick, step, linear,
                  read_addr, read_data, fraction, pcm, output_valid, player_ready, length);
    process
        type values_t is array(0 to CAPACITY-1) of integer;
        variable recorded : values_t := (others => 0);
        variable phase : natural := 0;
        variable active_length : positive := CAPACITY;
        procedure clocks(n : positive) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); wait for 1 ns; end loop;
        end procedure;
        procedure capture_clip(n : positive; seed : natural) is
        begin
            wait until falling_edge(clk); rec_start <= '1'; tick <= '0';
            clocks(1);
            assert recording = '1' and clip_ready = '0' and length = 0 severity failure;
            wait until falling_edge(clk); rec_start <= '0';
            for i in 0 to n-1 loop
                recorded(i) := ((41*i + 23*seed) mod 256) - 128;
                wait until falling_edge(clk);
                input_data <= to_signed(recorded(i), 8); input_valid <= '1';
                clocks(1); input_valid <= '0';
                assert count = i+1 and output_valid = '0' and player_ready = '0'
                    report "Recording count or playback exclusion failed" severity failure;
                if i < n-1 then clocks(2); end if; -- valid gaps must not create samples
            end loop;
            if n < CAPACITY then
                wait until falling_edge(clk); rec_stop <= '1';
                clocks(1);
                assert done = '0' and recording = '1' and clip_ready = '0' severity failure;
                wait until falling_edge(clk); rec_stop <= '0';
            end if;
            clocks(1);
            assert done = '1' and recording = '0' severity failure;
            if n >= 4 then
                assert clip_ready = '1' and length = n
                    report "Recorded length was not atomically committed" severity failure;
                active_length := n; phase := 0;
                clocks(10);
                assert player_ready = '1' and output_valid = '0' severity failure;
            else
                assert clip_ready = '0' and length = 0 severity failure;
            end if;
        end procedure;
        procedure playback(inc : natural; interpolate : boolean := true) is
            variable a, b, weighted, delta, expected : integer;
        begin
            a := recorded(phase/SCALE);
            b := recorded(((phase/SCALE)+1) mod active_length);
            expected := a;
            if interpolate then
                weighted := (b-a) * (phase mod SCALE);
                if weighted >= 0 then delta := (weighted+SCALE/2)/SCALE;
                else delta := -((-weighted+SCALE/2)/SCALE); end if;
                expected := a + delta;
            end if;
            wait until falling_edge(clk);
            assert player_ready = '1' severity failure;
            tick <= '1'; step <= to_unsigned(inc, step'length);
            if interpolate then linear <= '1'; else linear <= '0'; end if;
            clocks(1);
            assert output_valid = '1' and to_integer(pcm) = expected
                report "Recorded playback expected " & integer'image(expected) &
                       " got " & integer'image(to_integer(pcm)) severity failure;
            phase := (phase + inc) mod (active_length*SCALE);
            assert to_integer(fraction) = phase mod SCALE severity failure;
            wait until falling_edge(clk); tick <= '0';
            for age in 1 to 7 loop
                clocks(1);
                assert output_valid = '0' severity failure;
                if age < 7 then
                    assert player_ready = '0' report "Prefetch ready arrived too early" severity failure;
                else
                    assert player_ready = '1' report "Prefetch missed eight-clock tick budget" severity failure;
                end if;
            end loop;
        end procedure;
    begin
        clocks(3); rst <= '0'; clocks(10);
        assert clip_ready = '0' and length = 0 and player_ready = '0' severity failure;
        capture_clip(7, 1);
        for i in 1 to 28 loop playback(128); end loop;
        for i in 1 to 21 loop playback(384); end loop;
        for i in 1 to 21 loop playback(1023); end loop;
        for i in 1 to 10 loop playback(512, false); end loop;
        capture_clip(5, 2); -- stale addresses 5 and 6 must no longer be visited
        for i in 1 to 30 loop playback(320); end loop;
        capture_clip(CAPACITY, 3); -- automatic stop, including last physical write
        for i in 1 to 24 loop playback(256); end loop;
        capture_clip(4, 4); -- shortest supported clip at maximum legal pitch step
        for i in 1 to 40 loop playback(1023); end loop;
        capture_clip(3, 5); -- overwrites old data but cannot become playable
        wait until falling_edge(clk); tick <= '1';
        for i in 1 to 20 loop
            clocks(1);
            assert output_valid = '0' and pcm = 0 and player_ready = '0' severity failure;
        end loop;
        tick <= '0';
        capture_clip(6, 6); -- recovery after an invalid capture
        for i in 1 to 12 loop playback(256); end loop;
        wait until falling_edge(clk); rst <= '1'; clocks(1);
        rst <= '0'; clocks(10);
        assert clip_ready = '0' and length = 0 and pcm = 0 and output_valid = '0' severity failure;
        report "PASS: tb_record_playback" severity note;
        stop; wait;
    end process;
    process begin wait for 1 ms; assert false report "tb_record_playback timeout" severity failure; end process;
end architecture;
