-- Explicit three-byte UART packets, channel zero on this FPGA link.
-- 90 note velocity; 80 note velocity; B0 controller value.
-- CC64 is sustain; CC120/123 is panic (also clears sustain).
-- No running status. A new status resynchronizes, framing error aborts.
library ieee;
use ieee.std_logic_1164.all;

entity note_command_decoder is
    port (
        clk, rst : in std_logic;
        byte_data : in std_logic_vector(7 downto 0);
        byte_valid, framing_error : in std_logic;
        note_on, note_off : out std_logic;
        note_number, velocity : out std_logic_vector(6 downto 0);
        sustain_pedal : out std_logic := '0';
        panic : out std_logic := '0'
    );
end entity;

architecture rtl of note_command_decoder is
    type state_t is (WAIT_STATUS, WAIT_DATA1, WAIT_DATA2);
    type command_t is (NOTE_ON_COMMAND, NOTE_OFF_COMMAND, CONTROL_COMMAND);
    signal state_q : state_t := WAIT_STATUS;
    signal command_q : command_t := NOTE_OFF_COMMAND;
    signal first_data_q : std_logic_vector(6 downto 0) := (others => '0');
    signal note_q, velocity_q : std_logic_vector(6 downto 0) := (others => '0');
    signal on_q, off_q, sustain_q, panic_q : std_logic := '0';
begin
    note_on <= on_q;
    note_off <= off_q;
    note_number <= note_q;
    velocity <= velocity_q;
    sustain_pedal <= sustain_q;
    panic <= panic_q;

    process(clk)
    begin
        if rising_edge(clk) then
            on_q <= '0'; off_q <= '0'; panic_q <= '0';
            if rst = '1' then
                state_q <= WAIT_STATUS;
                command_q <= NOTE_OFF_COMMAND;
                first_data_q <= (others => '0');
                note_q <= (others => '0'); velocity_q <= (others => '0');
                sustain_q <= '0';
            elsif framing_error = '1' then
                state_q <= WAIT_STATUS;
            elsif byte_valid = '1' then
                if byte_data(7) = '1' then
                    state_q <= WAIT_DATA1;
                    case byte_data is
                        when x"90" => command_q <= NOTE_ON_COMMAND;
                        when x"80" => command_q <= NOTE_OFF_COMMAND;
                        when x"B0" => command_q <= CONTROL_COMMAND;
                        when others => state_q <= WAIT_STATUS;
                    end case;
                else
                    case state_q is
                        when WAIT_STATUS => null;
                        when WAIT_DATA1 =>
                            first_data_q <= byte_data(6 downto 0);
                            state_q <= WAIT_DATA2;
                        when WAIT_DATA2 =>
                            state_q <= WAIT_STATUS;
                            if command_q = CONTROL_COMMAND then
                                if first_data_q = "1000000" then
                                    sustain_q <= byte_data(6); -- value >=64
                                elsif first_data_q = "1111000" or first_data_q = "1111011" then
                                    panic_q <= '1';
                                    sustain_q <= '0';
                                end if;
                            else
                                note_q <= first_data_q;
                                velocity_q <= byte_data(6 downto 0);
                                if command_q = NOTE_ON_COMMAND and byte_data(6 downto 0) /= "0000000" then
                                    on_q <= '1';
                                else
                                    off_q <= '1';
                                end if;
                            end if;
                    end case;
                end if;
            end if;
        end if;
    end process;
end architecture;
