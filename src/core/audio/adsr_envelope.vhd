-- Preserved validated Stage 05 pipelined ADSR (VHDL-2008).
-- Single 100 MHz clock; sample_tick is a synchronous clock enable.
-- Exactly one output transaction is committed 2 clocks after each sample_tick.
-- REQUIREMENT: sample_tick pulses must be at least 3 clock periods apart.
-- gain_out is unsigned 0..65535 (0=silence, 65535=full gain).
-- Rate=0 means instantaneous phase; otherwise rate is 32-bit phase step.
-- For a phase lasting N ticks, use ceil(16#FFFFFFFF# / N), 1<=N<=65535.
-- Note events are 1-clock pulses; the last event before a tick wins.
-- Note-on has priority when note_on and note_off coincide.
-- New note parameters are captured with note_on, not on a later tick.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity adsr_envelope is
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;  -- synchronous, active high
        sample_tick   : in  std_logic;  -- single-clock pulse
        note_on       : in  std_logic;  -- single-clock pulse
        note_off      : in  std_logic;  -- single-clock pulse
        attack_rate   : in  unsigned(31 downto 0);
        decay_rate    : in  unsigned(31 downto 0);
        sustain_level : in  unsigned(15 downto 0);
        release_rate  : in  unsigned(31 downto 0);
        gain_out      : out unsigned(15 downto 0);
        active_out    : out std_logic;
        done_pulse    : out std_logic;
        gain_valid    : out std_logic
    );
end entity adsr_envelope;

architecture rtl of adsr_envelope is
    subtype level_t is unsigned(15 downto 0);
    subtype rate_t  is unsigned(31 downto 0);
    subtype sum_t   is unsigned(32 downto 0);

    type state_t is (ST_IDLE, ST_ATTACK, ST_DECAY, ST_SUSTAIN, ST_RELEASE);
    type command_t is (CMD_NONE, CMD_NOTE_ON, CMD_NOTE_OFF);

    constant LEVEL_ZERO : level_t := (others => '0');
    constant LEVEL_FULL : level_t := (others => '1');
    constant RATE_ZERO  : rate_t  := (others => '0');
    constant PHASE_FULL : rate_t  := (others => '1');
    constant MIN_RATE   : rate_t  := x"00010001";

    function limited_rate(value : rate_t) return rate_t is
    begin
        if value = RATE_ZERO then
            return RATE_ZERO;
        elsif value < MIN_RATE then
            return MIN_RATE;
        else
            return value;
        end if;
    end function;

    -- State and coefficients, updated at sample_tick.
    signal state_q         : state_t := ST_IDLE;
    signal segment_start_q : level_t := LEVEL_ZERO;
    signal segment_end_q   : level_t := LEVEL_ZERO;
    signal progress_q      : rate_t  := RATE_ZERO;
    signal current_rate_q  : rate_t  := RATE_ZERO;
    signal decay_rate_q    : rate_t  := RATE_ZERO;
    signal sustain_level_q : level_t := LEVEL_ZERO;
    signal release_rate_q  : rate_t  := RATE_ZERO;

    -- One-deep event mailbox; the newest command wins.
    signal pending_command_q : command_t := CMD_NONE;
    signal pending_attack_q  : rate_t  := RATE_ZERO;
    signal pending_decay_q   : rate_t  := RATE_ZERO;
    signal pending_sustain_q : level_t := LEVEL_ZERO;
    signal pending_release_q : rate_t  := RATE_ZERO;

    -- Pipeline stage 1: operands from phase update.
    signal s1_valid_q       : std_logic := '0';
    signal s1_interp_q      : std_logic := '0';
    signal s1_start_q       : level_t := LEVEL_ZERO;
    signal s1_delta_q       : level_t := LEVEL_ZERO;
    signal s1_fraction_q    : level_t := LEVEL_ZERO;
    signal s1_decreasing_q  : std_logic := '0';
    signal s1_direct_gain_q : level_t := LEVEL_ZERO;
    signal s1_active_q      : std_logic := '0';
    signal s1_done_q        : std_logic := '0';

    -- Pipeline stage 2: multiplier result and matching metadata.
    signal s2_valid_q       : std_logic := '0';
    signal s2_interp_q      : std_logic := '0';
    signal s2_start_q       : level_t := LEVEL_ZERO;
    signal s2_product_q     : unsigned(31 downto 0) := (others => '0');
    signal s2_decreasing_q  : std_logic := '0';
    signal s2_direct_gain_q : level_t := LEVEL_ZERO;
    signal s2_active_q      : std_logic := '0';
    signal s2_done_q        : std_logic := '0';

    -- Pipeline stage 3: public registered result.
    signal level_q      : level_t := LEVEL_ZERO;
    signal active_q     : std_logic := '0';
    signal done_q       : std_logic := '0';
    signal gain_valid_q : std_logic := '0';
begin
    gain_out   <= level_q;
    active_out <= active_q;
    done_pulse <= done_q;
    gain_valid <= gain_valid_q;

    process (clk)
        variable command_v       : command_t;
        variable attack_v        : rate_t;
        variable decay_v         : rate_t;
        variable sustain_v       : level_t;
        variable release_v       : rate_t;
        variable next_progress_v : sum_t;
        variable next_state_v    : state_t;
        variable target_gain_v   : level_t;
        variable start_v         : level_t;
        variable finish_v        : level_t;
        variable fraction_v      : level_t;
        variable interpolate_v   : std_logic;
        variable done_v          : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state_q           <= ST_IDLE;
                segment_start_q   <= LEVEL_ZERO;
                segment_end_q     <= LEVEL_ZERO;
                progress_q        <= RATE_ZERO;
                current_rate_q    <= RATE_ZERO;
                decay_rate_q      <= RATE_ZERO;
                sustain_level_q   <= LEVEL_ZERO;
                release_rate_q    <= RATE_ZERO;
                pending_command_q <= CMD_NONE;
                pending_attack_q  <= RATE_ZERO;
                pending_decay_q   <= RATE_ZERO;
                pending_sustain_q <= LEVEL_ZERO;
                pending_release_q <= RATE_ZERO;
                s1_valid_q       <= '0';
                s1_interp_q      <= '0';
                s1_start_q       <= LEVEL_ZERO;
                s1_delta_q       <= LEVEL_ZERO;
                s1_fraction_q    <= LEVEL_ZERO;
                s1_decreasing_q  <= '0';
                s1_direct_gain_q <= LEVEL_ZERO;
                s1_active_q      <= '0';
                s1_done_q        <= '0';
                s2_valid_q       <= '0';
                s2_interp_q      <= '0';
                s2_start_q       <= LEVEL_ZERO;
                s2_product_q     <= (others => '0');
                s2_decreasing_q  <= '0';
                s2_direct_gain_q <= LEVEL_ZERO;
                s2_active_q      <= '0';
                s2_done_q        <= '0';
                level_q      <= LEVEL_ZERO;
                active_q     <= '0';
                done_q       <= '0';
                gain_valid_q <= '0';
            else
                -- Stage 3: publish a completed gain transaction.
                done_q       <= '0';
                gain_valid_q <= '0';
                if s2_valid_q = '1' then
                    if s2_interp_q = '1' then
                        if s2_decreasing_q = '1' then
                            level_q <= s2_start_q - s2_product_q(31 downto 16);
                        else
                            level_q <= s2_start_q + s2_product_q(31 downto 16);
                        end if;
                    else
                        level_q <= s2_direct_gain_q;
                    end if;
                    active_q     <= s2_active_q;
                    done_q       <= s2_done_q;
                    gain_valid_q <= '1';
                end if;

                -- Stage 2: one 16x16 multiplication, with registered output.
                s2_valid_q <= s1_valid_q;
                if s1_valid_q = '1' then
                    s2_product_q     <= s1_delta_q * s1_fraction_q;
                    s2_interp_q      <= s1_interp_q;
                    s2_start_q       <= s1_start_q;
                    s2_decreasing_q  <= s1_decreasing_q;
                    s2_direct_gain_q <= s1_direct_gain_q;
                    s2_active_q      <= s1_active_q;
                    s2_done_q        <= s1_done_q;
                end if;

                -- Stage 1: collect control events and prepare next update.
                s1_valid_q <= '0';
                command_v := pending_command_q;
                attack_v  := pending_attack_q;
                decay_v   := pending_decay_q;
                sustain_v := pending_sustain_q;
                release_v := pending_release_q;

                if note_on = '1' then
                    command_v := CMD_NOTE_ON;
                    attack_v  := limited_rate(attack_rate);
                    decay_v   := limited_rate(decay_rate);
                    sustain_v := sustain_level;
                    release_v := limited_rate(release_rate);
                elsif note_off = '1' then
                    command_v := CMD_NOTE_OFF;
                end if;

                if sample_tick = '0' then
                    pending_command_q <= command_v;
                    if note_on = '1' then
                        pending_attack_q  <= attack_v;
                        pending_decay_q   <= decay_v;
                        pending_sustain_q <= sustain_v;
                        pending_release_q <= release_v;
                    end if;
                else
                    pending_command_q <= CMD_NONE;
                    next_state_v   := state_q;
                    target_gain_v  := level_q;
                    start_v        := LEVEL_ZERO;
                    finish_v       := LEVEL_ZERO;
                    fraction_v     := LEVEL_ZERO;
                    interpolate_v  := '0';
                    done_v         := '0';

                    if command_v = CMD_NOTE_ON then
                        -- Retrigger from last completed gain, not from zero.
                        decay_rate_q    <= decay_v;
                        sustain_level_q <= sustain_v;
                        release_rate_q  <= release_v;
                        progress_q      <= RATE_ZERO;

                        if attack_v = RATE_ZERO then
                            if decay_v = RATE_ZERO or sustain_v = LEVEL_FULL then
                                target_gain_v := sustain_v;
                                next_state_v  := ST_SUSTAIN;
                            else
                                target_gain_v   := LEVEL_FULL;
                                next_state_v    := ST_DECAY;
                                segment_start_q <= LEVEL_FULL;
                                segment_end_q   <= sustain_v;
                                current_rate_q  <= decay_v;
                            end if;
                        else
                            next_state_v    := ST_ATTACK;
                            segment_start_q <= level_q;
                            segment_end_q   <= LEVEL_FULL;
                            current_rate_q  <= attack_v;
                        end if;

                    elsif command_v = CMD_NOTE_OFF then
                        if state_q /= ST_IDLE then
                            progress_q <= RATE_ZERO;
                            if release_rate_q = RATE_ZERO or level_q = LEVEL_ZERO then
                                next_state_v  := ST_IDLE;
                                target_gain_v := LEVEL_ZERO;
                                done_v        := '1';
                            else
                                next_state_v    := ST_RELEASE;
                                segment_start_q <= level_q;
                                segment_end_q   <= LEVEL_ZERO;
                                current_rate_q  <= release_rate_q;
                            end if;
                        end if;

                    else
                        case state_q is
                            when ST_IDLE | ST_SUSTAIN =>
                                null;

                            when ST_ATTACK | ST_DECAY | ST_RELEASE =>
                                next_progress_v := ('0' & progress_q) +
                                                   ('0' & current_rate_q);
                                if next_progress_v >= ('0' & PHASE_FULL) then
                                    progress_q <= RATE_ZERO;
                                    case state_q is
                                        when ST_ATTACK =>
                                            target_gain_v := LEVEL_FULL;
                                            if decay_rate_q = RATE_ZERO or
                                               sustain_level_q = LEVEL_FULL then
                                                target_gain_v := sustain_level_q;
                                                next_state_v  := ST_SUSTAIN;
                                            else
                                                next_state_v    := ST_DECAY;
                                                segment_start_q <= LEVEL_FULL;
                                                segment_end_q   <= sustain_level_q;
                                                current_rate_q  <= decay_rate_q;
                                            end if;

                                        when ST_DECAY =>
                                            target_gain_v := sustain_level_q;
                                            next_state_v  := ST_SUSTAIN;

                                        when ST_RELEASE =>
                                            target_gain_v := LEVEL_ZERO;
                                            next_state_v  := ST_IDLE;
                                            done_v        := '1';

                                        when others =>
                                            null;
                                    end case;
                                else
                                    progress_q    <= next_progress_v(31 downto 0);
                                    start_v       := segment_start_q;
                                    finish_v      := segment_end_q;
                                    fraction_v    := next_progress_v(31 downto 16);
                                    interpolate_v := '1';
                                end if;
                        end case;
                    end if;

                    -- Register data and its matching state/done metadata.
                    state_q          <= next_state_v;
                    s1_valid_q       <= '1';
                    s1_interp_q      <= interpolate_v;
                    s1_start_q       <= start_v;
                    s1_fraction_q    <= fraction_v;
                    s1_direct_gain_q <= target_gain_v;
                    s1_done_q        <= done_v;
                    if next_state_v = ST_IDLE then
                        s1_active_q <= '0';
                    else
                        s1_active_q <= '1';
                    end if;
                    if finish_v >= start_v then
                        s1_delta_q      <= finish_v - start_v;
                        s1_decreasing_q <= '0';
                    else
                        s1_delta_q      <= start_v - finish_v;
                        s1_decreasing_q <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture rtl;