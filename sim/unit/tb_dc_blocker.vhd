library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
entity tb_dc_blocker is end entity;
architecture sim of tb_dc_blocker is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal in_valid, out_valid, clipped : std_logic := '0';
    signal pcm_i, pcm_o : signed(7 downto 0) := (others => '0');
begin
    clk <= not clk after 5 ns;
    dut : entity work.dc_blocker port map (clk, rst, in_valid, pcm_i, pcm_o, out_valid, clipped);
    process
        variable previous, state, checked, value : integer := 0;
        variable max_ac, min_ac : integer := 0;
        procedure send(x : integer) is
            variable leakage, result, expected : integer;
        begin
            if state > 0 then leakage := (state+255)/256;
            elsif state < 0 then leakage := -((-state+255)/256);
            else leakage := 0; end if;
            state := state+(x-previous)*256-leakage; previous := x;
            if state < 0 then result := -((-state+128)/256);
            else result := (state+128)/256; end if;
            expected := result;
            if expected > 127 then expected := 127; end if;
            if expected < -128 then expected := -128; end if;
            wait until falling_edge(clk); in_valid <= '1'; pcm_i <= to_signed(x, 8);
            wait until rising_edge(clk); wait for 1 ns;
            assert out_valid = '0' report "DC output arrived on input edge" severity failure;
            wait until falling_edge(clk); in_valid <= '0';
            wait until rising_edge(clk); wait for 1 ns;
            assert out_valid = '0' report "DC output arrived one clock early" severity failure;
            wait until rising_edge(clk); wait for 1 ns;
            assert out_valid = '1' and to_integer(pcm_o) = expected
                report "DC arithmetic or N+2 latency mismatch" severity failure;
            assert (clipped = '1') = (result > 127 or result < -128) severity failure;
            checked := checked+1;
        end procedure;
        procedure reset is
        begin
            wait until falling_edge(clk); rst <= '1'; in_valid <= '0';
            wait until rising_edge(clk); wait for 1 ns;
            assert pcm_o = 0 and out_valid = '0' and clipped = '0' severity failure;
            wait until falling_edge(clk); rst <= '0'; previous := 0; state := 0;
        end procedure;
    begin
        reset;
        send(64); assert pcm_o = 64 severity failure;
        for n in 1 to 2048 loop send(64); end loop;
        assert state = 0 and pcm_o = 0 report "Positive DC residue did not decay" severity failure;
        send(-64);
        for n in 1 to 2048 loop send(-64); end loop;
        assert state = 0 and pcm_o = 0 report "Negative DC residue did not decay" severity failure;
        send(0);
        for n in 1 to 2048 loop send(0); end loop;
        assert state = 0 and pcm_o = 0 report "Silence retained a filter residue" severity failure;
        send(-128); send(127); send(-128); send(127);
        for x in -128 to 127 loop send(x); end loop;
        reset;
        -- 1 kHz sinusoid on +30 DC. The passband component survives while
        -- the DC component is rejected. Integer oracle verifies each sample.
        for n in 0 to 4095 loop
            value := 30+integer(40.0*sin(2.0*MATH_PI*real(n)/16.0));
            send(value);
            if n > 2047 then
                if to_integer(pcm_o) > max_ac then max_ac := to_integer(pcm_o); end if;
                if to_integer(pcm_o) < min_ac then min_ac := to_integer(pcm_o); end if;
            end if;
        end loop;
        assert max_ac >= 38 and max_ac <= 42 and min_ac >= -42 and min_ac <= -38
            report "DC rejection damaged the 1 kHz passband" severity failure;
        -- Reset cancels the filter job before its public output.
        wait until falling_edge(clk); in_valid <= '1'; pcm_i <= to_signed(127, 8);
        wait until rising_edge(clk); wait for 1 ns;
        reset;
        for n in 1 to 8 loop
            wait until rising_edge(clk); wait for 1 ns;
            assert out_valid = '0' and pcm_o = 0 severity failure;
        end loop;
        send(0);
        report "PASS: tb_dc_blocker" severity note; stop; wait;
    end process;
    process begin wait for 10 ms; assert false report "tb_dc_blocker timeout" severity failure; end process;
end architecture;
