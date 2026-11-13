library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.audio_pkg.all;

entity tb_note_input_arbiter is end entity;
architecture sim of tb_note_input_arbiter is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal uart_on, uart_off, button_on, button_off : std_logic := '0';
    signal uart_note, uart_velocity : std_logic_vector(6 downto 0) := (others => '0');
    signal note_on, note_off, owner : std_logic;
    signal note_number, velocity : std_logic_vector(6 downto 0);
begin
    clk <= not clk after 5 ns;
    dut : entity work.note_input_arbiter
        port map (clk, rst, uart_on, uart_off, uart_note, uart_velocity,
                  button_on, button_off, note_on, note_off, note_number, velocity, owner);
    stimulus : process
        procedure step(uon, uoff : std_logic; n, v : natural;
                       press, release_button : std_logic) is
        begin
            wait until falling_edge(clk);
            uart_on <= uon; uart_off <= uoff;
            uart_note <= std_logic_vector(to_unsigned(n, 7));
            uart_velocity <= std_logic_vector(to_unsigned(v, 7));
            button_on <= press; button_off <= release_button;
            wait until rising_edge(clk); wait for 1 ns;
            assert not (note_on = '1' and note_off = '1')
                report "Arbiter emitted conflicting events" severity failure;
        end procedure;
        procedure check(on_event, off_event, expected_owner : std_logic;
                        n : natural := MIDI_ROOT_NOTE; v : natural := 0) is
        begin
            assert note_on = on_event and note_off = off_event and owner = expected_owner
                report "Arbiter event priority/ownership mismatch" severity failure;
            if on_event = '1' or off_event = '1' then
                assert unsigned(note_number) = n and unsigned(velocity) = v
                    report "Arbiter payload mismatch" severity failure;
            end if;
        end procedure;
    begin
        step('1', '1', 69, 127, '1', '1'); check('0', '0', '0');
        rst <= '0';
        step('0', '0', 0, 0, '0', '0'); check('0', '0', '0');
        step('0', '0', 0, 0, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
        step('0', '0', 0, 0, '0', '0'); check('0', '0', '1');
        -- UART off, matching or unmatched, must not end a button-owned voice.
        step('0', '1', 69, 0, '0', '0'); check('0', '0', '1');
        step('0', '1', 70, 0, '0', '0'); check('0', '0', '1');
        -- Concrete lost-release regression: UART off collides with button up.
        step('0', '1', 70, 0, '0', '1'); check('0', '1', '0', MIDI_ROOT_NOTE, 0);
        step('0', '0', 0, 0, '0', '0'); check('0', '0', '0');

        -- UART on takes over even the same pitch; old button release is stale.
        step('0', '0', 0, 0, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
        step('1', '0', 69, 127, '0', '0'); check('1', '0', '0', 69, 127);
        step('0', '0', 0, 0, '0', '1'); check('0', '0', '0');
        step('0', '1', 69, 0, '0', '0'); check('0', '1', '0', 69, 0);
        -- UART on wins simultaneous on/off, audition press, or audition release.
        step('1', '1', 81, 64, '1', '1'); check('1', '0', '0', 81, 64);
        step('0', '0', 0, 0, '0', '1'); check('0', '0', '0');
        step('0', '1', 81, 0, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
        step('1', '0', 57, 1, '0', '1'); check('1', '0', '0', 57, 1);
        -- Button release while UART owns must not suppress a real UART off.
        step('0', '1', 57, 0, '0', '1'); check('0', '1', '0', 57, 0);

        -- All MIDI note values exercise the shared validity/ownership bounds.
        for n in 0 to 127 loop
            step('0', '0', 0, 0, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
            step('1', '0', n, 100, '0', '0');
            if n >= MIDI_MIN_NOTE and n <= MIDI_MAX_NOTE then
                check('1', '0', '0', n, 100);
                step('0', '0', 0, 0, '0', '1'); check('0', '0', '0');
            else
                check('0', '0', '1');
                step('0', '1', n, 0, '0', '1'); check('0', '1', '0', MIDI_ROOT_NOTE, 0);
            end if;
        end loop;
        -- Invalid or zero-velocity UART-on cannot steal or suppress the UI.
        step('1', '0', 47, 100, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
        step('1', '0', 85, 100, '0', '1'); check('0', '1', '0', MIDI_ROOT_NOTE, 0);
        step('1', '0', 69, 0, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
        step('1', '0', 69, 0, '0', '1'); check('0', '1', '0', MIDI_ROOT_NOTE, 0);

        -- Global reset/record/panic flush ownership and pending output pulses.
        step('0', '0', 0, 0, '1', '0'); check('1', '0', '1', MIDI_ROOT_NOTE, 100);
        rst <= '1';
        step('1', '1', 81, 127, '1', '1'); check('0', '0', '0');
        rst <= '0';
        step('0', '0', 0, 0, '0', '0'); check('0', '0', '0');
        step('0', '0', 0, 0, '0', '1'); check('0', '0', '0');
        step('1', '0', 69, 127, '0', '0'); check('1', '0', '0', 69, 127);
        step('0', '0', 0, 0, '0', '0'); check('0', '0', '0');
        report "PASS: tb_note_input_arbiter" severity note;
        stop; wait;
    end process;
    watchdog : process
    begin
        wait for 100 us;
        assert false report "tb_note_input_arbiter timeout" severity failure;
    end process;
end architecture;
