-- Single-clock sample RAM: one write port and one registered read port.
-- Migrated from Stage 02. No reset is applied to the memory array.
-- At an edge, rd_data_o receives the OLD contents of rd_addr_i, including
-- a simultaneous write to that address (read-before-write RTL semantics).
-- INIT_FILE contains DEPTH rows of eight binary digits; extra rows are ignored.
-- INIT_FILE="" initializes all locations to zero, useful in unit tests.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity sample_ram is
    generic (
        ADDR_BITS : positive := 14;
        INIT_FILE : string := "sample_a4.mem"
    );
    port (
        clk_i     : in std_logic;
        wr_en_i   : in std_logic;
        wr_addr_i : in unsigned(ADDR_BITS-1 downto 0);
        wr_data_i : in signed(7 downto 0);
        rd_addr_i : in unsigned(ADDR_BITS-1 downto 0);
        rd_data_o : out signed(7 downto 0)
    );
end entity;

architecture rtl of sample_ram is
    type ram_t is array (0 to 2**ADDR_BITS-1) of bit_vector(7 downto 0);
    impure function load_ram(file_name : string) return ram_t is
        file ram_file : text;
        variable line_buffer : line;
        variable content : ram_t := (others => (others => '0'));
        variable good : boolean;
    begin
        if file_name /= "" then
            file_open(ram_file, file_name, read_mode);
            for i in content'range loop
                assert not endfile(ram_file)
                    report "sample_ram: initialization file is too short"
                    severity failure;
                readline(ram_file, line_buffer);
                read(line_buffer, content(i), good);
                assert good
                    report "sample_ram: invalid binary PCM at row " & integer'image(i)
                    severity failure;
            end loop;
            file_close(ram_file);
        end if;
        return content;
    end function;
    signal ram : ram_t := load_ram(INIT_FILE);
    attribute ram_style : string;
    attribute ram_style of ram : signal is "block";
    signal rd_reg : bit_vector(7 downto 0) := (others => '0');
begin
    process(clk_i)
    begin
        if rising_edge(clk_i) then
            if wr_en_i = '1' then
                ram(to_integer(wr_addr_i)) <=
                    to_bitvector(std_logic_vector(wr_data_i));
            end if;
            rd_reg <= ram(to_integer(rd_addr_i));
        end if;
    end process;
    rd_data_o <= signed(to_stdlogicvector(rd_reg));
end architecture;
