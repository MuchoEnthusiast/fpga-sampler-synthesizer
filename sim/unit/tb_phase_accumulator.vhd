-- Simulation only. Small non-power-of-two loop plus original 16000-sample wrap.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_phase_accumulator is end entity;
architecture sim of tb_phase_accumulator is
    constant SCALE : positive := 256;
    constant COUNT : positive := 7;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal advance : std_logic := '0';
    signal step : unsigned(9 downto 0) := (others => '0');
    signal idx : unsigned(3 downto 0);
    signal frac : unsigned(7 downto 0);
    signal sample_length : unsigned(4 downto 0) := to_unsigned(COUNT, 5);
    signal full_rst : std_logic := '1';
    signal full_advance : std_logic := '0';
    signal full_idx : unsigned(13 downto 0);
    signal full_frac : unsigned(15 downto 0);
    type steps_t is array(natural range <>) of natural;
    constant STEPS : steps_t := (0, 1, 64, 128, 256, 384, 512, 1023);
begin
    clk <= not clk after 5 ns;
    dut : entity work.phase_accumulator
        generic map (ADDR_BITS => 4, FRAC_BITS => 8, SAMPLE_COUNT => COUNT)
        port map (clk, rst, advance, step, idx, frac, sample_length);
    full_dut : entity work.phase_accumulator
        generic map (ADDR_BITS => 14, FRAC_BITS => 16, SAMPLE_COUNT => 16000)
        port map (clk, full_rst, full_advance, to_unsigned(131072, 18),
                  full_idx, full_frac);
    watchdog : process
    begin
        wait for 1 ms;
        assert false report "tb_phase_accumulator timeout" severity failure;
    end process;
    stimulus : process
        variable model : natural := 0;
        variable loop_length : positive := COUNT;
        procedure cycle(s : natural; enable : boolean) is
        begin
            wait until falling_edge(clk);
            step <= to_unsigned(s, step'length);
            if enable then advance <= '1'; else advance <= '0'; end if;
            wait until rising_edge(clk);
            wait for 1 ns;
            if enable then model := (model+s) mod (loop_length*SCALE); end if;
            assert to_integer(idx) = model/SCALE and
                   to_integer(frac) = model mod SCALE
                report "phase/index/fraction mismatch" severity failure;
        end procedure;
    begin
        wait until rising_edge(clk);
        wait for 1 ns;
        assert idx = 0 and frac = 0 severity failure;
        wait until falling_edge(clk);
        rst <= '0';
        for s in STEPS'range loop
            for i in 1 to 40 loop cycle(STEPS(s), true); end loop;
            cycle(1023, false);
        end loop;
        -- Reset has priority over advance and clears both phase fields.
        wait until falling_edge(clk);
        rst <= '1'; advance <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert idx = 0 and frac = 0 severity failure;
        wait until falling_edge(clk);
        rst <= '0'; advance <= '0'; model := 0;
        cycle(128, true);
        cycle(256, true);
        cycle(0, true);

        -- Dynamic short, non-power-of-two and full-capacity clip lengths.
        for length in 4 to 16 loop
            wait until falling_edge(clk);
            rst <= '1'; advance <= '0'; sample_length <= to_unsigned(length, 5);
            wait until rising_edge(clk); wait for 1 ns;
            assert idx = 0 and frac = 0 severity failure;
            wait until falling_edge(clk); rst <= '0';
            model := 0; loop_length := length;
            for s in STEPS'range loop
                for i in 1 to 20 loop cycle(STEPS(s), true); end loop;
            end loop;
        end loop;
        -- An uncommitted/invalid length must not expose an old address.
        for bad_length in 0 to 3 loop
            wait until falling_edge(clk);
            sample_length <= to_unsigned(bad_length, 5); advance <= '1';
            wait until rising_edge(clk); wait for 1 ns;
            assert idx = 0 and frac = 0 severity failure;
        end loop;
        wait until falling_edge(clk); sample_length <= to_unsigned(17, 5);
        wait until rising_edge(clk); wait for 1 ns;
        assert idx = 0 and frac = 0 severity failure;

        wait until falling_edge(clk);
        full_rst <= '0'; full_advance <= '1';
        for n in 1 to 8000 loop
            wait until rising_edge(clk);
            wait for 1 ns;
            assert to_integer(full_idx) = (2*n) mod 16000 and full_frac = 0
                report "16000-sample wrap mismatch" severity failure;
        end loop;
        report "PASS: tb_phase_accumulator" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
