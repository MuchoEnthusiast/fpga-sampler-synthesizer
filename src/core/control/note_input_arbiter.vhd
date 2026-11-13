library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audio_pkg.all;

-- Arbitrate one monophonic voice between the UART and local audition button.
-- Events sampled at N are published immediately after N; a downstream clocked
-- consumer sees them at N+1. Invalid cycles clear the event pulses and retain
-- payload. Reset flushes ownership and any published pulse; no event queue.
-- Priority: valid UART on > audition press > owned audition release > UART off.
-- The decoder converts real zero-velocity MIDI on packets to note-off first.
entity note_input_arbiter is
    port (
        clk, rst : in std_logic;
        uart_note_on, uart_note_off : in std_logic;
        uart_note_number, uart_velocity : in std_logic_vector(6 downto 0);
        audition_press, audition_release : in std_logic;
        note_on, note_off : out std_logic;
        note_number, velocity : out std_logic_vector(6 downto 0);
        audition_owns_voice : out std_logic
    );
end entity;

architecture rtl of note_input_arbiter is
    signal owns_q, on_q, off_q : std_logic := '0';
    signal note_q : std_logic_vector(6 downto 0) :=
        std_logic_vector(to_unsigned(MIDI_ROOT_NOTE, 7));
    signal velocity_q : std_logic_vector(6 downto 0) := (others => '0');
begin
    note_on <= on_q;
    note_off <= off_q;
    note_number <= note_q;
    velocity <= velocity_q;
    audition_owns_voice <= owns_q;
    process(clk)
        variable incoming_note : natural range 0 to 127;
    begin
        if rising_edge(clk) then
            on_q <= '0'; off_q <= '0';
            if rst = '1' then
                owns_q <= '0';
                note_q <= std_logic_vector(to_unsigned(MIDI_ROOT_NOTE, 7));
                velocity_q <= (others => '0');
            else
                incoming_note := to_integer(unsigned(uart_note_number));
                if uart_note_on = '1' and uart_velocity /= "0000000" and
                   incoming_note >= MIDI_MIN_NOTE and incoming_note <= MIDI_MAX_NOTE then
                    owns_q <= '0'; on_q <= '1';
                    note_q <= uart_note_number; velocity_q <= uart_velocity;
                elsif audition_press = '1' then
                    owns_q <= '1'; on_q <= '1';
                    note_q <= std_logic_vector(to_unsigned(MIDI_ROOT_NOTE, 7));
                    velocity_q <= std_logic_vector(to_unsigned(100, 7));
                elsif audition_release = '1' and owns_q = '1' then
                    owns_q <= '0'; off_q <= '1';
                    note_q <= std_logic_vector(to_unsigned(MIDI_ROOT_NOTE, 7));
                    velocity_q <= (others => '0');
                elsif uart_note_off = '1' and owns_q = '0' then
                    off_q <= '1';
                    note_q <= uart_note_number; velocity_q <= (others => '0');
                end if;
            end if;
        end if;
    end process;
end architecture;
