-- UART receiver + explicit three-byte note protocol regression.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_uart_control is end entity;
architecture sim of tb_uart_control is
    constant CLOCK_PERIOD : time := 10 ns;
    constant CLKS_PER_BIT : positive := 16;
    constant BIT_PERIOD : time := CLOCK_PERIOD * CLKS_PER_BIT;
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal rx_line : std_logic := '1';
    signal byte_data : std_logic_vector(7 downto 0);
    signal byte_valid, framing_error, note_on, note_off : std_logic;
    signal note_number, velocity : std_logic_vector(6 downto 0);
    signal sustain, panic : std_logic;
    signal panic_count : natural := 0;
    signal on_count, off_count, err_count, byte_count : natural := 0;
begin
    clk <= not clk after CLOCK_PERIOD/2;
    receiver : entity work.uart_rx generic map (CLKS_PER_BIT => CLKS_PER_BIT)
        port map (clk => clk, rst => rst, rx_i => rx_line, data_out => byte_data,
                  data_valid => byte_valid, framing_error => framing_error);
    decoder : entity work.note_command_decoder port map (
        clk => clk, rst => rst, byte_data => byte_data, byte_valid => byte_valid,
        framing_error => framing_error, note_on => note_on, note_off => note_off,
        note_number => note_number, velocity => velocity,
        sustain_pedal => sustain, panic => panic
    );
    monitor : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                on_count <= 0; off_count <= 0; err_count <= 0; byte_count <= 0; panic_count <= 0;
            else
                assert not (note_on = '1' and note_off = '1')
                    report "On and off asserted together" severity failure;
                if note_on = '1' then on_count <= on_count + 1; end if;
                if note_off = '1' then off_count <= off_count + 1; end if;
                if framing_error = '1' then err_count <= err_count + 1; end if;
                if byte_valid = '1' then byte_count <= byte_count + 1; end if;
                if panic = '1' then panic_count <= panic_count + 1; end if;
            end if;
        end if;
    end process;
    watchdog : process begin
        wait for 1 ms;
        assert false report "tb_uart_control timeout" severity failure;
    end process;
    stimulus : process
        procedure send_byte(value : std_logic_vector(7 downto 0); good_stop : boolean := true) is
        begin
            rx_line <= '0'; wait for BIT_PERIOD;
            for b in 0 to 7 loop
                rx_line <= value(b); wait for BIT_PERIOD;
            end loop;
            if good_stop then rx_line <= '1'; else rx_line <= '0'; end if;
            wait for BIT_PERIOD;
            rx_line <= '1';
        end procedure;
        procedure command(status : std_logic_vector(7 downto 0); n, v : natural) is
        begin
            send_byte(status);
            send_byte(std_logic_vector(to_unsigned(n, 8)));
            send_byte(std_logic_vector(to_unsigned(v, 8)));
            wait for 5*CLOCK_PERIOD;
        end procedure;
        procedure reset is
        begin
            rst <= '1'; rx_line <= '1'; wait for 4*CLOCK_PERIOD;
            rst <= '0'; wait for 4*CLOCK_PERIOD;
        end procedure;
    begin
        reset;
        -- Every byte value, with frames adjacent and no extra idle bit.
        for b in 0 to 255 loop
            send_byte(std_logic_vector(to_unsigned(b, 8)));
            assert byte_data = std_logic_vector(to_unsigned(b, 8))
                report "UART byte mismatch" severity failure;
        end loop;
        wait for 5*CLOCK_PERIOD;
        assert byte_count = 256 and err_count = 0 severity failure;
        reset;
        -- Pulse shorter than half a bit must be rejected as a false start.
        rx_line <= '0'; wait for 3*CLOCK_PERIOD;
        rx_line <= '1'; wait for 2*BIT_PERIOD;
        assert byte_count = 0 and err_count = 0 report "False start accepted" severity failure;

        command(x"90", 60, 100);
        assert on_count = 1 and off_count = 0 and unsigned(note_number) = 60 and unsigned(velocity) = 100
            report "Note-on mismatch" severity failure;
        command(x"80", 61, 0);
        assert off_count = 1 and unsigned(note_number) = 61 severity failure;
        command(x"80", 60, 0);
        assert off_count = 2 and unsigned(note_number) = 60 severity failure;
        command(x"90", 69, 0);
        assert off_count = 3 and on_count = 1 and unsigned(note_number) = 69
            report "Zero velocity is not note-off" severity failure;
        send_byte(x"45"); send_byte(x"7F"); wait for 5*CLOCK_PERIOD;
        assert on_count = 1 report "Unexpected running-status acceptance" severity failure;

        send_byte(x"90"); send_byte(x"3C"); send_byte(x"64", false);
        wait for 3*BIT_PERIOD;
        assert err_count = 1 and on_count = 1 report "Framing error handling failed" severity failure;
        send_byte(x"64"); wait for 5*CLOCK_PERIOD;
        assert on_count = 1 report "Bad frame left a partial command" severity failure;
        command(x"91", 60, 100);
        assert on_count = 1 report "Unsupported channel accepted" severity failure;

        send_byte(x"90"); send_byte(x"3C");
        command(x"90", 69, 127);
        assert on_count = 2 and unsigned(note_number) = 69 and unsigned(velocity) = 127
            report "New status did not resynchronize" severity failure;
        send_byte(x"90"); send_byte(x"3C");
        reset; -- discard a partially received note packet
        send_byte(x"64"); wait for 5*CLOCK_PERIOD;
        assert on_count = 0 and off_count = 0 and err_count = 0 severity failure;
        command(x"90", 60, 100);
        assert on_count = 1 and unsigned(note_number) = 60 report "Recovery after reset failed" severity failure;
        -- Sustain thresholds and complete controller packets.
        command(x"B0", 64, 63);
        assert sustain = '0' severity failure;
        command(x"B0", 64, 64);
        assert sustain = '1' and panic_count = 0 severity failure;
        command(x"B0", 64, 127);
        assert sustain = '1' and on_count = 1 and off_count = 0 severity failure;
        command(x"B0", 7, 0); -- unrelated controller is ignored
        assert sustain = '1' and panic_count = 0 severity failure;
        command(x"B0", 64, 0);
        assert sustain = '0' severity failure;
        command(x"B0", 64, 127);
        send_byte(x"B0"); send_byte(x"40"); send_byte(x"00", false);
        wait for 3*BIT_PERIOD;
        assert sustain = '1' report "Bad CC frame changed sustain" severity failure;
        send_byte(x"00"); wait for 5*CLOCK_PERIOD;
        assert sustain = '1' report "Aborted CC packet was retained" severity failure;
        command(x"B0", 123, 0);
        assert sustain = '0' and panic_count = 1 severity failure;
        command(x"B0", 64, 127);
        command(x"B0", 120, 0);
        assert sustain = '0' and panic_count = 2 severity failure;
        send_byte(x"B0"); send_byte(x"40");
        command(x"90", 69, 100); -- status replaces an incomplete CC
        assert on_count = 2 and sustain = '0' severity failure;
        command(x"B0", 64, 127); reset;
        assert sustain = '0' and panic_count = 0 severity failure;
        report "PASS: tb_uart_control" severity note;
        stop; wait;
    end process;
end architecture;
