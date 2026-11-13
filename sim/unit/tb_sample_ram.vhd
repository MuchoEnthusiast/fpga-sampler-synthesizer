-- Simulation only: initialization, registered read, boundaries and collisions.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_sample_ram is end entity;
architecture sim of tb_sample_ram is
    signal clk : std_logic := '0';
    signal wr_en : std_logic := '0';
    signal wr_addr, rd_addr : unsigned(3 downto 0) := (others => '0');
    signal wr_data : signed(7 downto 0) := (others => '0');
    signal rd_data : signed(7 downto 0);
    function value_at(a : natural) return integer is
    begin return (37*a) mod 256 - 128; end function;
begin
    clk <= not clk after 5 ns;
    dut : entity work.sample_ram
        generic map (ADDR_BITS => 4, INIT_FILE => "")
        port map (clk, wr_en, wr_addr, wr_data, rd_addr, rd_data);
    watchdog : process
    begin
        wait for 100 us;
        assert false report "tb_sample_ram timeout" severity failure;
    end process;
    stimulus : process
        variable old_output : signed(7 downto 0);
    begin
        for a in 0 to 15 loop
            wait until falling_edge(clk);
            rd_addr <= to_unsigned(a, 4);
            wait until rising_edge(clk);
            wait for 1 ns;
            assert rd_data = 0 report "empty init is not zero" severity failure;
        end loop;
        for a in 0 to 15 loop
            wait until falling_edge(clk);
            wr_en <= '1'; wr_addr <= to_unsigned(a, 4);
            wr_data <= to_signed(value_at(a), 8);
        end loop;
        wait until falling_edge(clk);
        wr_en <= '0';
        for a in 0 to 15 loop
            wait until falling_edge(clk);
            old_output := rd_data;
            rd_addr <= to_unsigned(a, 4);
            wait for 1 ns;
            assert rd_data = old_output
                report "read output changed without a clock edge" severity failure;
            wait until rising_edge(clk);
            wait for 1 ns;
            assert to_integer(rd_data) = value_at(a)
                report "RAM signed readback mismatch" severity failure;
        end loop;
        -- Same address read/write returns old value on the collision edge.
        wait until falling_edge(clk);
        rd_addr <= to_unsigned(5, 4); wr_addr <= to_unsigned(5, 4);
        wr_data <= to_signed(127, 8); wr_en <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert to_integer(rd_data) = value_at(5)
            report "RAM read-before-write mismatch" severity failure;
        wait until falling_edge(clk);
        wr_en <= '0'; wr_data <= to_signed(-128, 8);
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rd_data = 127 report "RAM write did not persist" severity failure;
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rd_data = 127 report "disabled write changed RAM" severity failure;
        -- Independent simultaneous ports: read address 5 while writing 15.
        wait until falling_edge(clk);
        wr_addr <= to_unsigned(15, 4); wr_data <= to_signed(-128, 8); wr_en <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rd_data = 127 severity failure;
        wait until falling_edge(clk);
        wr_en <= '0'; rd_addr <= to_unsigned(15, 4);
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rd_data = -128 severity failure;
        report "PASS: tb_sample_ram" severity note;
        std.env.stop;
        wait;
    end process;
end architecture;
