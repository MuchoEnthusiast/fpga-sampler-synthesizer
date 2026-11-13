-- PCM recorder with explicit clip metadata and a single-clock RAM write port.
-- Press start to invalidate the previous clip and begin at address zero.
-- Start/stop are synchronous one-clock pulses. Samples are accepted only
-- in CAPTURE. Start is ignored while busy;
-- stop wins over a simultaneous PCM sample. A clip needs at least 4 samples.
-- MAX_SAMPLES accepts exactly that many samples, then stops automatically.
-- The final write occurs at N; metadata/done commit at N+1. Keep the player
-- reset while recording='1', including the COMMIT cycle. No RAM reset/clear.
-- PRELOADED_SAMPLES is valid only before the first recording starts; reset
-- after RAM modification must not claim that the initial image still exists.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity record_controller is
    generic (
        ADDR_BITS : positive := 14;
        MAX_SAMPLES : positive := 16000;
        PRELOADED_SAMPLES : natural := 0
    );
    port (
        clk, rst : in std_logic;
        record_start, record_stop : in std_logic;
        sample_valid : in std_logic;
        sample_data : in signed(7 downto 0);
        wr_en : out std_logic;
        wr_addr : out unsigned(ADDR_BITS-1 downto 0);
        wr_data : out signed(7 downto 0);
        recording, sample_ready, record_done : out std_logic;
        sample_length, recorded_count : out unsigned(ADDR_BITS downto 0) := (others => '0')
    );
end entity;

architecture rtl of record_controller is
    type state_t is (IDLE, CAPTURE, COMMIT);
    signal state_q : state_t := IDLE;
    signal count_q : unsigned(ADDR_BITS downto 0) := (others => '0');
    signal length_q : unsigned(ADDR_BITS downto 0) :=
        to_unsigned(PRELOADED_SAMPLES, ADDR_BITS+1);
    signal done_q : std_logic := '0';
    -- Configuration-time initialization, deliberately not restored by reset.
    signal pristine_q : std_logic := '1';
    signal write_enable : std_logic;
begin
    assert MAX_SAMPLES >= 4 and MAX_SAMPLES <= 2**ADDR_BITS
        report "record_controller: MAX_SAMPLES must be 4..RAM depth" severity failure;
    assert PRELOADED_SAMPLES = 0 or
           (PRELOADED_SAMPLES >= 4 and PRELOADED_SAMPLES <= 2**ADDR_BITS)
        report "record_controller: invalid PRELOADED_SAMPLES" severity failure;

    write_enable <= '1' when state_q = CAPTURE and sample_valid = '1'
                     and record_stop = '0' and rst = '0' else '0';
    wr_en <= write_enable;
    wr_addr <= count_q(ADDR_BITS-1 downto 0);
    wr_data <= sample_data;
    recording <= '1' when state_q /= IDLE else '0';
    sample_ready <= '1' when state_q = IDLE and length_q >= 4 and rst = '0' else '0';
    record_done <= done_q;
    sample_length <= length_q;
    recorded_count <= count_q;

    process(clk)
    begin
        if rising_edge(clk) then
            done_q <= '0';
            if rst = '1' then
                state_q <= IDLE;
                count_q <= (others => '0');
                length_q <= (others => '0');
                if pristine_q = '1' then
                    length_q <= to_unsigned(PRELOADED_SAMPLES, length_q'length);
                end if;
            else
                case state_q is
                    when IDLE =>
                        if record_start = '1' and record_stop = '0' then
                            state_q <= CAPTURE;
                            count_q <= (others => '0');
                            length_q <= (others => '0');
                            pristine_q <= '0';
                        end if;
                    when CAPTURE =>
                        if record_stop = '1' then
                            state_q <= COMMIT;
                        elsif write_enable = '1' then
                            count_q <= count_q + 1;
                            if count_q = to_unsigned(MAX_SAMPLES-1, count_q'length) then
                                state_q <= COMMIT;
                            end if;
                        end if;
                    when COMMIT =>
                        if count_q >= 4 then length_q <= count_q;
                        else length_q <= (others => '0'); end if;
                        state_q <= IDLE;
                        done_q <= '1';
                end case;
            end if;
        end if;
    end process;
end architecture;
