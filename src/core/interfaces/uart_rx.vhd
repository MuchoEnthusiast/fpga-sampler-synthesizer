library ieee;
use ieee.std_logic_1164.all;

-- 8N1 UART receiver, LSB first, no flow control.
-- 868 clocks/bit at 100 MHz gives approximately 115200 baud.
entity uart_rx is
    generic (
        CLKS_PER_BIT : positive := 868
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        rx_i          : in  std_logic;
        data_out      : out std_logic_vector(7 downto 0);
        data_valid    : out std_logic;
        framing_error : out std_logic
    );
end entity;

architecture rtl of uart_rx is
    type state_t is (
        IDLE, START_BIT, DATA_BITS, STOP_BIT, WAIT_IDLE
    );

    signal state_q       : state_t := IDLE;
    signal rx_meta_q     : std_logic := '1';
    signal rx_sync_q     : std_logic := '1';
    signal timer_q       : natural range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_index_q   : natural range 0 to 7 := 0;
    signal shift_q       : std_logic_vector(7 downto 0) := (others => '0');
    signal data_q        : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_q       : std_logic := '0';
    signal frame_error_q : std_logic := '0';
    attribute ASYNC_REG : string;
    attribute ASYNC_REG of rx_meta_q, rx_sync_q : signal is "TRUE";
begin
    assert CLKS_PER_BIT >= 8
        report "uart_rx requires CLKS_PER_BIT >= 8"
        severity failure;

    data_out      <= data_q;
    data_valid    <= valid_q;
    framing_error <= frame_error_q;

    process (clk)
    begin
        if rising_edge(clk) then
            -- Synchronize incoming serial signal.
            rx_meta_q <= rx_i;
            rx_sync_q <= rx_meta_q;

            valid_q       <= '0';
            frame_error_q <= '0';

            if rst = '1' then
                rx_meta_q   <= '1';
                rx_sync_q   <= '1';
                state_q     <= IDLE;
                timer_q     <= 0;
                bit_index_q <= 0;
                shift_q     <= (others => '0');
                data_q      <= (others => '0');
            else
                case state_q is
                    when IDLE =>
                        if rx_sync_q = '0' then
                            timer_q <= CLKS_PER_BIT / 2 - 1;
                            state_q <= START_BIT;
                        end if;

                    when START_BIT =>
                        if timer_q = 0 then
                            if rx_sync_q = '0' then
                                timer_q     <= CLKS_PER_BIT - 1;
                                bit_index_q <= 0;
                                state_q     <= DATA_BITS;
                            else
                                -- False start bit.
                                state_q <= IDLE;
                            end if;
                        else
                            timer_q <= timer_q - 1;
                        end if;

                    when DATA_BITS =>
                        if timer_q = 0 then
                            shift_q(bit_index_q) <= rx_sync_q;
                            timer_q <= CLKS_PER_BIT - 1;

                            if bit_index_q = 7 then
                                state_q <= STOP_BIT;
                            else
                                bit_index_q <= bit_index_q + 1;
                            end if;
                        else
                            timer_q <= timer_q - 1;
                        end if;

                    when STOP_BIT =>
                        if timer_q = 0 then
                            if rx_sync_q = '1' then
                                data_q  <= shift_q;
                                valid_q <= '1';
                                state_q <= IDLE;
                            else
                                frame_error_q <= '1';
                                state_q <= WAIT_IDLE;
                            end if;
                        else
                            timer_q <= timer_q - 1;
                        end if;

                    when WAIT_IDLE =>
                        -- Recover after a malformed frame.
                        if rx_sync_q = '1' then
                            state_q <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture;
