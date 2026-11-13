library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_delay_effect is
    generic (DELAY_SAMPLES : positive := 5);
end entity;
architecture sim of tb_delay_effect is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal input_valid, ready, enabled, output_valid : std_logic := '0';
    signal input_pcm, output_pcm : signed(15 downto 0) := (others => '0');
begin
    clk <= not clk after 5 ns;
    dut : entity work.delay_effect
        generic map (G_DELAY_SAMPLES => DELAY_SAMPLES)
        port map (clk, rst, input_valid, ready, input_pcm, enabled,
                  output_valid, output_pcm);
    watchdog : process
    begin
        wait for 1 ms;
        assert false report "tb_delay_effect timeout" severity failure;
    end process;
    stimulus : process
        procedure reset_dut is
        begin
            wait until falling_edge(clk);
            rst <= '1'; input_valid <= '1';
            wait until rising_edge(clk); wait for 1 ns;
            assert ready = '0' and output_valid = '0' and output_pcm = 0
                report "Echo reset failed" severity failure;
            wait until falling_edge(clk);
            rst <= '0'; input_valid <= '0';
        end procedure;

        procedure send_sample(x : integer; en : std_logic; expected : integer) is
        begin
            wait until falling_edge(clk);
            assert ready = '1' report "Echo not ready" severity failure;
            input_pcm <= to_signed(x, 16); enabled <= en; input_valid <= '1';
            wait until rising_edge(clk); wait for 1 ns;
            assert ready = '0' and output_valid = '0'
                report "Incorrect echo acceptance/latency" severity failure;
            wait until falling_edge(clk);
            input_valid <= '0';
            -- Input and mode are latched at acceptance, not at completion.
            input_pcm <= to_signed(12345, 16); enabled <= not en;
            wait until rising_edge(clk); wait for 1 ns;
            assert output_valid = '1' and ready = '1'
                report "Incorrect echo completion/ready" severity failure;
            assert to_integer(output_pcm) = expected
                report "Echo expected " & integer'image(expected) &
                       ", got " & integer'image(to_integer(output_pcm))
                severity failure;
        end procedure;

        procedure zeros_between_echoes is
        begin
            for i in 1 to DELAY_SAMPLES-1 loop send_sample(0, '1', 0); end loop;
        end procedure;
    begin
        reset_dut;
        -- Retain original Stage 09 impulse and feedback-through-bypass checks.
        send_sample(12000, '1', 12000); zeros_between_echoes;
        send_sample(0, '1', 6000); zeros_between_echoes;
        send_sample(0, '0', 0); zeros_between_echoes;
        send_sample(0, '1', 1500);

        reset_dut;
        send_sample(30000, '1', 30000); zeros_between_echoes;
        send_sample(30000, '1', 32767);
        reset_dut;
        send_sample(-30000, '1', -30000); zeros_between_echoes;
        send_sample(-30000, '1', -32768);

        -- Stale RAM must be masked for a complete refill and later wraps.
        reset_dut;
        for i in 1 to 2*DELAY_SAMPLES+1 loop send_sample(0, '1', 0); end loop;

        -- Preserve the documented signed-shift rounding, including -1 residue.
        reset_dut;
        send_sample(-3, '1', -3); zeros_between_echoes;
        send_sample(0, '1', -2); zeros_between_echoes;
        send_sample(0, '1', -1); zeros_between_echoes;
        send_sample(0, '1', -1);

        -- A reset while a sample is pending cancels the transaction.
        wait until falling_edge(clk);
        input_valid <= '1'; input_pcm <= to_signed(20000, 16);
        wait until rising_edge(clk); wait for 1 ns;
        assert ready = '0' severity failure;
        reset_dut;
        for i in 1 to DELAY_SAMPLES+1 loop send_sample(0, '1', 0); end loop;

        -- Hold a second valid transaction through backpressure. It must be
        -- accepted exactly once when ready returns, preserving input order.
        reset_dut;
        wait until falling_edge(clk);
        input_valid <= '1'; input_pcm <= to_signed(1000, 16); enabled <= '0';
        wait until rising_edge(clk); wait for 1 ns;
        assert ready = '0' and output_valid = '0' severity failure;
        wait until falling_edge(clk); input_pcm <= to_signed(2000, 16);
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '1' and output_pcm = 1000 and ready = '1'
            report "Busy input corrupted the first transaction" severity failure;
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '0' and ready = '0'
            report "Second transaction was not accepted on ready" severity failure;
        wait until falling_edge(clk); input_valid <= '0';
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '1' and output_pcm = 2000
            report "Second transaction lost, duplicated or reordered" severity failure;
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '0' and ready = '1'
            report "Output valid was not a one-clock pulse" severity failure;
        report "PASS: tb_delay_effect" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
