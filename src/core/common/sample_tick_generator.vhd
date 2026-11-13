library ieee;
use ieee.std_logic_1164.all;

entity sample_tick_generator is
    generic (DIVIDER : positive := 6250);
    port (clk, rst : in std_logic; sample_tick : out std_logic);
end entity;

architecture rtl of sample_tick_generator is
    signal count : natural range 0 to DIVIDER - 1 := 0;
    signal tick : std_logic := '0';
begin
    assert DIVIDER >= 2 report "DIVIDER must be at least 2" severity failure;
    sample_tick <= tick;
    process(clk)
    begin
        if rising_edge(clk) then
            tick <= '0';
            if rst = '1' then
                count <= 0;
            elsif count = DIVIDER - 1 then
                count <= 0;
                tick <= '1';
            else
                count <= count + 1;
            end if;
        end if;
    end process;
end architecture;
