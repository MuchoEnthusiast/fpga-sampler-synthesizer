library ieee;
use ieee.std_logic_1164.all;
use std.env.all;
entity tb_button_debouncer is end entity;
architecture sim of tb_button_debouncer is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal input, level, pressed : std_logic := '0';
    signal immediate_level, immediate_pressed : std_logic;
begin
    clk <= not clk after 5 ns;
    dut : entity work.button_debouncer generic map (STABLE_CYCLES => 4)
        port map (clk, rst, input, level, pressed);
    single : entity work.button_debouncer generic map (STABLE_CYCLES => 1)
        port map (clk, rst, input, immediate_level, immediate_pressed);
    process
        variable last_input : std_logic := '0';
        procedure cycle(value, expected_level, expected_pulse : std_logic) is
        begin
            wait until falling_edge(clk); input <= value;
            wait until rising_edge(clk); wait for 1 ns;
            assert level = expected_level and pressed = expected_pulse
                report "Debounce stable-period/pulse mismatch" severity failure;
            assert immediate_level = value severity failure;
            if value = '1' and last_input = '0' then
                assert immediate_pressed = '1' severity failure;
            else assert immediate_pressed = '0' severity failure; end if;
            last_input := value;
        end procedure;
    begin
        wait until rising_edge(clk); wait for 1 ns;
        assert level = '0' and pressed = '0' severity failure;
        rst <= '0';
        cycle('1','0','0'); cycle('1','0','0'); cycle('0','0','0');
        cycle('1','0','0'); cycle('0','0','0');
        for i in 1 to 3 loop cycle('1','0','0'); end loop;
        cycle('1','1','1');
        for i in 1 to 8 loop cycle('1','1','0'); end loop;
        cycle('0','1','0'); cycle('0','1','0'); cycle('1','1','0');
        for i in 1 to 3 loop cycle('0','1','0'); end loop;
        cycle('0','0','0');
        for i in 1 to 3 loop cycle('1','0','0'); end loop;
        cycle('1','1','1');
        wait until falling_edge(clk); rst <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        assert level = '0' and pressed = '0' and immediate_pressed = '0'
            report "Reset failed during a held press" severity failure;
        report "PASS: tb_button_debouncer" severity note; stop; wait;
    end process;
    process begin wait for 100 us; assert false report "tb_button_debouncer timeout" severity failure; end process;
end architecture;
