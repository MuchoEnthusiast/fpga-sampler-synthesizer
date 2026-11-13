-- Simulation only. Independent integer reference, valid bubbles and reset flush.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_linear_interpolator is end entity;
architecture sim of tb_linear_interpolator is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal in_valid, out_valid : std_logic := '0';
    signal a, b, pcm : signed(7 downto 0) := (others => '0');
    signal frac : unsigned(7 downto 0) := (others => '0');
    type integers_t is array(natural range <>) of integer;
    type booleans_t is array(natural range <>) of boolean;
    constant VALUES : integers_t := (-128, -127, -64, -1, 0, 1, 63, 126, 127);
    constant FRACTIONS : integers_t := (0, 1, 63, 127, 128, 129, 254, 255);
    function reference(x, y, f : integer) return integer is
        variable product, delta, result : integer;
    begin
        product := (y-x)*f;
        if product >= 0 then delta := (product+128)/256;
        else delta := -((-product+128)/256); end if;
        result := x+delta;
        if result > 127 then return 127;
        elsif result < -128 then return -128;
        else return result; end if;
    end function;
begin
    clk <= not clk after 5 ns;
    dut : entity work.linear_interpolator
        generic map (FRAC_BITS => 8)
        port map (clk, rst, in_valid, a, b, frac, pcm, out_valid);
    watchdog : process
    begin
        wait for 1 ms;
        assert false report "tb_linear_interpolator timeout" severity failure;
    end process;
    stimulus : process
        variable expected : integers_t(0 to 1) := (others => 0);
        variable valid : booleans_t(0 to 1) := (others => false);
        variable last_pcm : integer := 0;
        procedure cycle(x, y, f : integer; enable : boolean := true) is
        begin
            wait until falling_edge(clk);
            a <= to_signed(x, 8); b <= to_signed(y, 8); frac <= to_unsigned(f, 8);
            if enable then in_valid <= '1'; else in_valid <= '0'; end if;
            wait until rising_edge(clk);
            wait for 1 ns;
            if valid(1) then
                assert out_valid = '1' and to_integer(pcm) = expected(1)
                    report "interpolation value or N+2 latency mismatch" severity failure;
                last_pcm := expected(1);
            else
                assert out_valid = '0' and to_integer(pcm) = last_pcm
                    report "invalid interpolation cycle changed output" severity failure;
            end if;
            valid(1) := valid(0); expected(1) := expected(0);
            valid(0) := enable; expected(0) := reference(x, y, f);
        end procedure;
    begin
        wait until rising_edge(clk);
        wait for 1 ns;
        assert out_valid = '0' and pcm = 0 severity failure;
        wait until falling_edge(clk);
        rst <= '0';
        for i in VALUES'range loop
            for j in VALUES'range loop
                for k in FRACTIONS'range loop
                    cycle(VALUES(i), VALUES(j), FRACTIONS(k));
                end loop;
                cycle(0, 0, 0, false);
            end loop;
        end loop;
        for f in 0 to 255 loop
            cycle(-128, 127, f);
            cycle(127, -128, f);
        end loop;
        for i in 1 to 3 loop cycle(0, 0, 0, false); end loop;
        cycle(127, -128, 128);
        -- Reset while an accepted operation is still in flight.
        wait until falling_edge(clk);
        rst <= '1'; in_valid <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert pcm = 0 and out_valid = '0' severity failure;
        valid := (others => false); expected := (others => 0); last_pcm := 0;
        wait until falling_edge(clk);
        rst <= '0';
        for i in 1 to 3 loop cycle(0, 0, 0, false); end loop;
        cycle(-128, 127, 0);
        for i in 1 to 3 loop cycle(0, 0, 0, false); end loop;
        report "PASS: tb_linear_interpolator" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
