library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_effects_chain is end entity;
architecture sim of tb_effects_chain is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal input_valid, distort_enable, drive4, echo_enable : std_logic := '0';
    signal input_pcm, distorted_pcm : signed(7 downto 0) := (others => '0');
    signal distorted_valid, echo_ready, output_valid : std_logic;
    signal echo_input, output_pcm : signed(15 downto 0);
begin
    clk <= not clk after 5 ns;
    u_distortion : entity work.distortion
        port map (clk, rst, input_valid, input_pcm, distort_enable, drive4,
                  distorted_pcm, distorted_valid);
    -- Preserve full-scale amplitude when crossing the 8/16-bit boundary.
    echo_input <= shift_left(resize(distorted_pcm, 16), 8);
    u_delay : entity work.delay_effect
        generic map (G_DELAY_SAMPLES => 3)
        port map (clk, rst, distorted_valid, echo_ready, echo_input,
                  echo_enable, output_valid, output_pcm);

    handshake_check : process(clk)
    begin
        if rising_edge(clk) and rst = '0' and distorted_valid = '1' then
            assert echo_ready = '1'
                report "Effects chain dropped a sample while echo busy"
                severity failure;
        end if;
    end process;
    watchdog : process
    begin
        wait for 100 us;
        assert false report "tb_effects_chain timeout" severity failure;
    end process;

    stimulus : process
        procedure reset_chain is
        begin
            wait until falling_edge(clk); rst <= '1'; input_valid <= '0';
            wait until rising_edge(clk); wait for 1 ns;
            assert distorted_valid = '0' and output_valid = '0' and output_pcm = 0
                report "Chain reset failed" severity failure;
            wait until falling_edge(clk); rst <= '0';
        end procedure;

        procedure send_sample(x : integer; distortion_on, echo_on : std_logic;
                              expected16 : integer) is
        begin
            wait until falling_edge(clk);
            input_valid <= '1'; input_pcm <= to_signed(x, 8);
            distort_enable <= distortion_on; drive4 <= '1'; echo_enable <= echo_on;
            wait until rising_edge(clk); wait for 1 ns; -- N: distortion output.
            assert distorted_valid = '1' and output_valid = '0'
                report "Incorrect distortion stage latency" severity failure;
            wait until falling_edge(clk); input_valid <= '0';
            wait until rising_edge(clk); wait for 1 ns; -- N+1: echo accepts.
            assert distorted_valid = '0' and echo_ready = '0' and output_valid = '0'
                report "Incorrect echo input scheduling" severity failure;
            wait until rising_edge(clk); wait for 1 ns; -- N+2: echo result.
            assert output_valid = '1' and echo_ready = '1'
                report "Incorrect chain output latency" severity failure;
            assert to_integer(output_pcm) = expected16
                report "Chain expected " & integer'image(expected16) &
                       ", got " & integer'image(to_integer(output_pcm))
                severity failure;
        end procedure;
    begin
        reset_chain;
        send_sample(32, '1', '1', 32512); -- distortion saturates to +127.
        send_sample(0, '1', '1', 0);
        send_sample(0, '1', '1', 0);
        send_sample(0, '1', '1', 16256); -- dry voice stopped; echo continues.
        send_sample(0, '0', '1', 0);
        send_sample(0, '0', '1', 0);
        send_sample(0, '0', '0', 0);     -- bypass hides, but stores, next echo.
        send_sample(0, '0', '1', 0);
        send_sample(0, '0', '1', 0);
        send_sample(0, '0', '1', 4064);

        reset_chain;
        send_sample(-40, '1', '1', -32768);
        send_sample(0, '0', '1', 0);
        -- Fabric-clock gaps do not advance the delay's audio-sample pointer.
        wait for 100 ns;
        assert output_valid = '0' and output_pcm = 0 severity failure;
        send_sample(0, '0', '1', 0);
        send_sample(0, '0', '1', -16384);

        reset_chain;
        send_sample(100, '0', '1', 25600);
        send_sample(0, '0', '1', 0);
        send_sample(0, '0', '1', 0);
        send_sample(100, '0', '1', 32767); -- echo saturates independently.

        -- Reset cancels a sample between the distortion and echo stages.
        wait until falling_edge(clk); input_valid <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        reset_chain;
        for i in 1 to 7 loop send_sample(0, '0', '1', 0); end loop;
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '0' report "Output valid did not clear" severity failure;
        report "PASS: tb_effects_chain" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
