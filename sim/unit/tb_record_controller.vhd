library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_record_controller is
    generic (MAX_SAMPLES_G : positive := 10);
end entity;
architecture sim of tb_record_controller is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal start_i, stop_i, input_valid : std_logic := '0';
    signal input_data, write_data : signed(7 downto 0) := (others => '0');
    signal write_enable, busy, ready, done : std_logic;
    signal write_addr : unsigned(3 downto 0);
    signal length, count : unsigned(4 downto 0);
    signal writes : natural := 0;
    type ram_t is array(0 to 15) of integer;
    signal observed : ram_t := (others => 0);
begin
    clk <= not clk after 5 ns;
    dut : entity work.record_controller
        generic map (ADDR_BITS => 4, MAX_SAMPLES => MAX_SAMPLES_G, PRELOADED_SAMPLES => 4)
        port map (clk, rst, start_i, stop_i, input_valid, input_data,
                  write_enable, write_addr, write_data, busy, ready, done, length, count);
    observe_write_port : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                assert write_enable = '0' report "Write enabled during reset" severity failure;
                writes <= 0;
            elsif write_enable = '1' then
                writes <= writes + 1;
                observed(to_integer(write_addr)) <= to_integer(write_data);
            end if;
        end if;
    end process;
    process
        variable before : natural;
        procedure cycle(s, t, v : std_logic := '0'; x : integer := 0) is
        begin
            wait until falling_edge(clk);
            start_i <= s; stop_i <= t; input_valid <= v; input_data <= to_signed(x, 8);
            wait until rising_edge(clk); wait for 1 ns;
        end procedure;
    begin
        assert MAX_SAMPLES_G >= 4 and MAX_SAMPLES_G <= 16 severity failure;
        wait until rising_edge(clk); wait for 1 ns;
        assert busy = '0' and ready = '0' and done = '0' severity failure;
        rst <= '0'; cycle;
        assert ready = '1' and length = 4 report "Pristine initial sample missing" severity failure;

        -- Stop takes priority over a simultaneous start, leaving the clip intact.
        cycle('1', '1', '1', 99);
        assert busy = '0' and ready = '1' and length = 4 and writes = 0 severity failure;
        cycle('1', '0', '1', 99); -- starting edge does not also write a PCM sample
        assert busy = '1' and ready = '0' and length = 0 and count = 0 and writes = 0 severity failure;
        cycle('0', '0', '0', 77);
        assert count = 0 and writes = 0 report "Invalid PCM was recorded" severity failure;
        cycle('0', '0', '1', -128);
        cycle('1', '0', '1', 127); -- another start while busy must not restart
        cycle('0', '0', '1', 31);
        assert count = 3 and writes = 3 and observed(0) = -128 and observed(1) = 127 and observed(2) = 31
            report "Start while busy reset count or changed write ordering" severity failure;
        cycle('0', '1', '1', 66); -- stop wins over sample
        assert busy = '1' and ready = '0' and done = '0' and count = 3 and writes = 3 severity failure;
        cycle;
        assert busy = '0' and ready = '0' and done = '1' and length = 0
            report "A clip shorter than four samples was marked playable" severity failure;
        cycle;
        assert done = '0' report "record_done must be a one-clock pulse" severity failure;

        -- A new short but valid clip has no stale length or sample count.
        before := writes;
        cycle('1');
        for i in 0 to 3 loop cycle('0', '0', '1', i * 17 - 20); end loop;
        cycle('0', '1');
        assert done = '0' and busy = '1' and ready = '0' severity failure;
        cycle;
        assert done = '1' and ready = '1' and length = 4 and count = 4 and writes = before + 4 severity failure;
        for i in 0 to 3 loop assert observed(i) = i * 17 - 20 severity failure; end loop;

        -- Automatic full stop accepts the last sample exactly once, publishes
        -- metadata one edge later, and cannot wrap and overwrite address zero.
        before := writes;
        cycle('1');
        for i in 0 to MAX_SAMPLES_G-1 loop
            cycle('0', '0', '1', i * 7 - 50);
            assert count = i+1 and ready = '0' and done = '0' and busy = '1' severity failure;
        end loop;
        assert writes = before + MAX_SAMPLES_G severity failure;
        assert observed(MAX_SAMPLES_G-1) = (MAX_SAMPLES_G-1)*7 - 50
            report "Final sample was not written before commit" severity failure;
        cycle('0', '0', '1', 120);
        assert ready = '1' and done = '1' and busy = '0' and length = MAX_SAMPLES_G severity failure;
        for i in 1 to 3 loop cycle('0', '0', '1', 120); end loop;
        assert writes = before + MAX_SAMPLES_G and observed(0) = -50
            report "Recorder overwrote a committed full clip" severity failure;

        -- Reset after overwrite cannot resurrect PRELOADED_SAMPLES metadata.
        wait until falling_edge(clk); rst <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        rst <= '0'; cycle;
        assert ready = '0' and length = 0 and count = 0 and done = '0'
            report "Reset falsely restored overwritten preload metadata" severity failure;

        -- Reset during COMMIT cancels the pending completion.
        cycle('1');
        for i in 0 to 3 loop cycle('0', '0', '1', i); end loop;
        cycle('0', '1');
        wait until falling_edge(clk); rst <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        rst <= '0'; cycle;
        assert ready = '0' and done = '0' and length = 0 severity failure;
        report "PASS: tb_record_controller" severity note;
        stop; wait;
    end process;
    process begin wait for 100 us; assert false report "tb_record_controller timeout" severity failure; end process;
end architecture;
