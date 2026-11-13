library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_distortion is end entity;
architecture sim of tb_distortion is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal input_valid, enable, drive4, output_valid : std_logic := '0';
    signal input_pcm, output_pcm : signed(7 downto 0) := (others => '0');
begin
    clk <= not clk after 5 ns;
    dut : entity work.distortion
        port map (clk, rst, input_valid, input_pcm, enable, drive4,
                  output_pcm, output_valid);
    watchdog : process
    begin
        wait for 100 us;
        assert false report "tb_distortion timeout" severity failure;
    end process;
    stimulus : process
        variable expected : integer;
        variable previous : signed(7 downto 0);
    begin
        wait until rising_edge(clk);
        wait for 1 ns;
        assert output_valid = '0' and output_pcm = 0
            report "Reset failed" severity failure;
        rst <= '0';
        -- Original Stage 08 exhaustive coverage: 256 x 2 x 2 = 1024.
        for e in 0 to 1 loop
            for d in 0 to 1 loop
                for x in -128 to 127 loop
                    expected := x;
                    if e = 1 then expected := x * (2 + 2*d); end if;
                    if expected > 127 then expected := 127; end if;
                    if expected < -128 then expected := -128; end if;
                    wait until falling_edge(clk);
                    input_pcm <= to_signed(x, 8);
                    input_valid <= '1';
                    if e = 1 then enable <= '1'; else enable <= '0'; end if;
                    if d = 1 then drive4 <= '1'; else drive4 <= '0'; end if;
                    wait until rising_edge(clk);
                    wait for 1 ns;
                    assert output_valid = '1' and to_integer(output_pcm) = expected
                        report "Distortion mismatch for input " & integer'image(x)
                        severity failure;
                end loop;
            end loop;
        end loop;
        previous := output_pcm;
        wait until falling_edge(clk);
        input_valid <= '0'; input_pcm <= to_signed(17, 8);
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '0' and output_pcm = previous
            report "Invalid cycle changed PCM or asserted valid" severity failure;
        wait until falling_edge(clk);
        input_valid <= '1'; rst <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        assert output_valid = '0' and output_pcm = 0
            report "Reset did not override valid input" severity failure;
        report "PASS: tb_distortion" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
