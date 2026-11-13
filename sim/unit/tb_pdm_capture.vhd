library ieee;
use ieee.std_logic_1164.all;
use std.env.all;

entity tb_pdm_capture is end entity;

architecture sim of tb_pdm_capture is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal mic_data : std_logic := 'Z';
    signal mic_clk, lrsel, ready, bit_value, bit_valid : std_logic;
    signal model_bit : std_logic := '0';
    signal rise_time : time := 0 ns;
    signal accepted : natural := 0;
begin
    clk <= not clk after 5 ns;
    dut : entity work.pdm_capture
        generic map (G_HALF_PERIOD_CYCLES => 25, G_WARMUP_CYCLES => 200)
        port map (clk, rst, mic_data, mic_clk, lrsel, ready, bit_value, bit_valid);

    -- Model assumptions: DATA drives 60 ns after falling M_CLK,
    -- and becomes high impedance 5 ns after rising M_CLK.
    microphone : process(mic_clk)
        constant pattern : std_logic_vector(0 to 7) := "10100111";
        variable index : natural range 0 to 7 := 0;
    begin
        if falling_edge(mic_clk) then
            model_bit <= pattern(index);
            mic_data <= pattern(index) after 60 ns;
            index := (index + 1) mod 8;
        elsif rising_edge(mic_clk) then
            rise_time <= now;
            mic_data <= 'Z' after 5 ns;
        end if;
    end process;

    check_clock : process(mic_clk, rst)
        variable previous_edge : time := 0 ns;
    begin
        if rst = '1' then
            previous_edge := 0 ns;
        elsif mic_clk'event then
            if previous_edge /= 0 ns then
                assert now - previous_edge = 250 ns
                    report "Incorrect microphone half-period" severity failure;
            end if;
            previous_edge := now;
        end if;
    end process;

    check_capture : process
        variable active_cycles : natural := 0;
        variable previous_valid : std_logic := '0';
        variable previous_time : time := 0 ns;
    begin
        wait until rising_edge(clk);
        wait for 1 ns;
        assert lrsel = '0' report "Wrong microphone channel" severity failure;
        if rst = '1' then
            active_cycles := 0;
            previous_valid := '0';
            previous_time := 0 ns;
            accepted <= 0;
            assert bit_valid = '0' and ready = '0' and mic_clk = '0'
                report "Reset failed" severity failure;
        else
            active_cycles := active_cycles + 1;
            if active_cycles < 200 then
                assert ready = '0' and bit_valid = '0'
                    report "Warm-up ended too early" severity failure;
            else
                assert ready = '1' report "Ready missing" severity failure;
            end if;
            if bit_valid = '1' then
                assert previous_valid = '0'
                    report "Valid is wider than one cycle" severity failure;
                assert now - rise_time = 21 ns
                    report "Incorrect two-cycle capture latency" severity failure;
                assert bit_value = model_bit
                    report "Captured wrong bit or inactive half-cycle" severity failure;
                if previous_time /= 0 ns then
                    assert now - previous_time = 500 ns
                        report "Missing or duplicate sample" severity failure;
                end if;
                previous_time := now;
                accepted <= accepted + 1;
            end if;
            previous_valid := bit_valid;
        end if;
    end process;

    stimulus : process
    begin
        wait for 100 ns;
        wait until falling_edge(clk);
        rst <= '0';
        wait until accepted = 20;
        -- Reset between the pin capture and the delayed valid pulse.
        wait until rising_edge(mic_clk);
        wait until falling_edge(clk);
        rst <= '1';
        wait for 100 ns;
        wait until falling_edge(clk);
        rst <= '0';
        wait until accepted = 8;
        report "PASS: tb_pdm_capture" severity note;
        stop;
        wait;
    end process;

    watchdog : process
    begin
        wait for 100 us;
        assert false report "Capture test timed out" severity failure;
    end process;
end architecture;