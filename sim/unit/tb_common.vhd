library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.audio_pkg.all;

entity tb_common is end entity;
architecture sim of tb_common is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal tick : std_logic;
    signal async_bits, sync_bits : std_logic_vector(1 downto 0) := "00";
begin
    clk <= not clk after 5 ns;
    u_tick : entity work.sample_tick_generator generic map (DIVIDER => 7)
        port map (clk, rst, tick);
    u_sync : entity work.input_synchronizer generic map (WIDTH => 2)
        port map (clk, async_bits, sync_bits);
    process
        variable expected : integer;
    begin
        for n in -32768 to 32767 loop
            if n < 0 then expected := -((-n + 128) / 256);
            else expected := (n + 128) / 256; end if;
            if expected > 127 then expected := 127; end if;
            if expected < -128 then expected := -128; end if;
            assert to_integer(narrow_pcm(to_signed(n, 16))) = expected
                report "PCM narrowing mismatch" severity failure;
        end loop;
        for n in -128 to 127 loop
            assert to_integer(widen_pcm(to_signed(n, 8))) = n * 256 severity failure;
            assert narrow_pcm(widen_pcm(to_signed(n, 8))) = to_signed(n, 8) severity failure;
        end loop;
        wait until rising_edge(clk); wait for 1 ns;
        assert tick = '0' and sync_bits = "00" severity failure;
        wait until falling_edge(clk); rst <= '0'; async_bits <= "10";
        for cycle in 1 to 28 loop
            wait until rising_edge(clk); wait for 1 ns;
            if cycle mod 7 = 0 then assert tick = '1' severity failure;
            else assert tick = '0' severity failure; end if;
            if cycle = 1 then assert sync_bits = "00" severity failure;
            else assert sync_bits = "10" severity failure; end if;
        end loop;
        wait until falling_edge(clk); rst <= '1'; async_bits <= "01";
        wait until rising_edge(clk); wait for 1 ns;
        assert tick = '0' and sync_bits = "10" severity failure;
        wait until rising_edge(clk); wait for 1 ns;
        assert tick = '0' and sync_bits = "01" severity failure;
        report "PASS: tb_common" severity note; stop; wait;
    end process;
    process begin wait for 10 us; assert false report "tb_common timeout" severity failure; end process;
end architecture;
