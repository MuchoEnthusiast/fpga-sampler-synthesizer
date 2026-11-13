-- Last-note monophonic policy, MIDI 48..84, stored sample root A4=69.
-- Note-off only releases the current note; CC64 holds released keys.
-- held_o includes sustain. A panic overrides all events. Step UQ2.16.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audio_pkg.all;

entity note_event_manager is
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        note_on_i       : in  std_logic;
        note_off_i      : in  std_logic;
        note_number_i   : in  std_logic_vector(6 downto 0);
        velocity_i      : in  std_logic_vector(6 downto 0);

        note_number_o   : out std_logic_vector(6 downto 0);
        velocity_o      : out unsigned(6 downto 0);
        step_o          : out unsigned(17 downto 0);

        held_o          : out std_logic;
        start_pulse_o   : out std_logic;
        release_pulse_o : out std_logic;
        sustain_pedal   : in std_logic := '0';
        panic           : in std_logic := '0'
    );
end entity;

architecture rtl of note_event_manager is

    -- The bundled test sample is A4 = 440 Hz.
    -- MIDI note number for A4 is 69.

    -- Q2.16 pitch increment lookup table.
    --
    -- step(n) = round(2^((n - 69)/12) * 2^16)
    --
    -- MIDI 69 = A4 -> step = 65536 -> original pitch.
    -- MIDI 57 = A3 -> step = 32768 -> half speed.
    -- MIDI 81 = A5 -> step = 131072 -> double speed.
    --
    -- Synthesizable ROM-style combinational lookup.

    function pitch_step(n : integer) return unsigned is
    begin
        case n is
            when 48 => return to_unsigned(19484, 18);
            when 49 => return to_unsigned(20643, 18);
            when 50 => return to_unsigned(21870, 18);
            when 51 => return to_unsigned(23170, 18);
            when 52 => return to_unsigned(24548, 18);
            when 53 => return to_unsigned(26008, 18);
            when 54 => return to_unsigned(27554, 18);
            when 55 => return to_unsigned(29193, 18);
            when 56 => return to_unsigned(30929, 18);
            when 57 => return to_unsigned(32768, 18);
            when 58 => return to_unsigned(34716, 18);
            when 59 => return to_unsigned(36781, 18);
            when 60 => return to_unsigned(38968, 18);
            when 61 => return to_unsigned(41285, 18);
            when 62 => return to_unsigned(43740, 18);
            when 63 => return to_unsigned(46341, 18);
            when 64 => return to_unsigned(49097, 18);
            when 65 => return to_unsigned(52016, 18);
            when 66 => return to_unsigned(55109, 18);
            when 67 => return to_unsigned(58386, 18);
            when 68 => return to_unsigned(61858, 18);
            when 69 => return to_unsigned(65536, 18);
            when 70 => return to_unsigned(69433, 18);
            when 71 => return to_unsigned(73562, 18);
            when 72 => return to_unsigned(77936, 18);
            when 73 => return to_unsigned(82570, 18);
            when 74 => return to_unsigned(87480, 18);
            when 75 => return to_unsigned(92682, 18);
            when 76 => return to_unsigned(98193, 18);
            when 77 => return to_unsigned(104032, 18);
            when 78 => return to_unsigned(110218, 18);
            when 79 => return to_unsigned(116772, 18);
            when 80 => return to_unsigned(123715, 18);
            when 81 => return to_unsigned(131072, 18);
            when 82 => return to_unsigned(138866, 18);
            when 83 => return to_unsigned(147123, 18);
            when 84 => return to_unsigned(155872, 18);
            when others =>
                return to_unsigned(65536, 18);
        end case;
    end function;

    signal note_q : std_logic_vector(6 downto 0)
        := std_logic_vector(to_unsigned(MIDI_ROOT_NOTE, 7));

    signal velocity_q : unsigned(6 downto 0)
        := (others => '0');

    signal step_q : unsigned(17 downto 0)
        := to_unsigned(65536, 18);

    signal held_q    : std_logic := '0';
    signal start_q   : std_logic := '0';
    signal release_q : std_logic := '0';
    signal key_down_q : std_logic := '0';

begin

    process(clk)
        variable received_note : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then

                note_q <= std_logic_vector(
                    to_unsigned(MIDI_ROOT_NOTE, 7)
                );

                velocity_q <= (others => '0');
                step_q     <= to_unsigned(65536, 18);

                held_q    <= '0';
                start_q   <= '0';
                release_q <= '0';
                key_down_q <= '0';

            else

                -- Pulses default to zero each clock cycle.
                start_q   <= '0';
                release_q <= '0';

                received_note :=
                    to_integer(unsigned(note_number_i));

                if panic = '1' then
                    held_q <= '0'; key_down_q <= '0';
                    release_q <= '1';
                elsif note_on_i = '1' and velocity_i /= "0000000" and
                   received_note >= MIDI_MIN_NOTE and
                   received_note <= MIDI_MAX_NOTE then

                    note_q     <= note_number_i;
                    velocity_q <= unsigned(velocity_i);
                    step_q     <= pitch_step(received_note);

                    held_q  <= '1';
                    key_down_q <= '1';
                    start_q <= '1';

                elsif (note_off_i = '1' or
                       (note_on_i = '1' and velocity_i = "0000000")) and
                      note_number_i = note_q and held_q = '1' then
                    key_down_q <= '0';
                    if sustain_pedal = '0' then
                        held_q <= '0'; release_q <= '1';
                    end if;
                elsif held_q = '1' and key_down_q = '0' and sustain_pedal = '0' then
                    held_q <= '0'; release_q <= '1';
                end if;
            end if;
        end if;
    end process;

    note_number_o   <= note_q;
    velocity_o      <= velocity_q;
    step_o          <= step_q;

    held_o          <= held_q;
    start_pulse_o   <= start_q;
    release_pulse_o <= release_q;

end architecture;
