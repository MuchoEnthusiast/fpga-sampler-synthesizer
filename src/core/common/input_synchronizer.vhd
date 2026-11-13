library ieee;
use ieee.std_logic_1164.all;

-- Independent slowly changing control bits, not a coherent data bus.
-- Startup is zero. Core reset is derived from a synchronized reset button.
entity input_synchronizer is
    generic (WIDTH : positive := 1);
    port (
        clk : in std_logic;
        async_i : in std_logic_vector(WIDTH - 1 downto 0);
        sync_o : out std_logic_vector(WIDTH - 1 downto 0)
    );
end entity;

architecture rtl of input_synchronizer is
    signal meta_q, sync_q : std_logic_vector(WIDTH - 1 downto 0)
        := (others => '0');
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of meta_q, sync_q : signal is "TRUE";
    attribute SHREG_EXTRACT : string;
    attribute SHREG_EXTRACT of meta_q, sync_q : signal is "NO";
begin
    process(clk)
    begin
        if rising_edge(clk) then
            meta_q <= async_i;
            sync_q <= meta_q;
        end if;
    end process;
    sync_o <= sync_q;
end architecture;
