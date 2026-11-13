-- Stage 05: self-checking pipelined ADSR testbench (VHDL-2008).
-- Simulation only. Generates sample_tick faster than a real 16 kHz enable.
-- The RTL requires at least 3 system clock cycles between sample_ticks.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_adsr_envelope is
end entity tb_adsr_envelope;

architecture sim of tb_adsr_envelope is
    constant CLK_PERIOD : time := 10 ns;
    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';
    signal sample_tick   : std_logic := '0';
    signal note_on       : std_logic := '0';
    signal note_off      : std_logic := '0';
    signal attack_rate   : unsigned(31 downto 0) := x"40000000";
    signal decay_rate    : unsigned(31 downto 0) := x"80000000";
    signal sustain_level : unsigned(15 downto 0) := x"8000";
    signal release_rate  : unsigned(31 downto 0) := x"40000000";
    signal gain_out      : unsigned(15 downto 0);
    signal active_out    : std_logic;
    signal done_pulse    : std_logic;
    signal gain_valid    : std_logic;

    -- Apply one tick and return after its result is committed at T+2.
    procedure tick(
        signal clk_s  : in  std_logic;
        signal tick_s : out std_logic
    ) is
    begin
        wait until falling_edge(clk_s);
        tick_s <= '1';
        wait until rising_edge(clk_s); -- T: first pipeline register
        wait for 1 ns;
        tick_s <= '0';
        wait until rising_edge(clk_s); -- T+1: multiply register
        wait until rising_edge(clk_s); -- T+2: gain register
        wait for 1 ns;
    end procedure;

    -- Send one note event *between* sample ticks.
    procedure pulse(
        signal clk_s   : in  std_logic;
        signal pulse_s : out std_logic
    ) is
    begin
        wait until falling_edge(clk_s);
        pulse_s <= '1';
        wait until rising_edge(clk_s);
        wait for 1 ns;
        pulse_s <= '0';
    end procedure;

    procedure check_gain(
        signal actual : in unsigned(15 downto 0);
        constant expected : in natural;
        constant label_text : in string
    ) is
    begin
        assert to_integer(actual) = expected
            report label_text & ": expected " & integer'image(expected) &
                   ", got " & integer'image(to_integer(actual))
            severity failure;
    end procedure;

    procedure check_commit(
        signal valid_s : in std_logic;
        constant label_text : in string
    ) is
    begin
        assert valid_s = '1'
            report label_text & ": missing gain_valid" severity failure;
    end procedure;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.adsr_envelope(rtl)
        port map (
            clk           => clk,
            rst           => rst,
            sample_tick   => sample_tick,
            note_on       => note_on,
            note_off      => note_off,
            attack_rate   => attack_rate,
            decay_rate    => decay_rate,
            sustain_level => sustain_level,
            release_rate  => release_rate,
            gain_out      => gain_out,
            active_out    => active_out,
            done_pulse    => done_pulse,
            gain_valid    => gain_valid
        );

    watchdog : process
    begin
        wait for 10 ms;
        assert false report "tb_adsr_envelope timeout" severity failure;
    end process;

    stimulus : process
    begin
        -- 1. Reset must clear the output and entire pipeline.
        tick(clk, sample_tick);
        check_gain(gain_out, 0, "reset level");
        assert active_out = '0' and done_pulse = '0' and gain_valid = '0'
            report "reset status invalid" severity failure;
        rst <= '0';

        -- 2. Note-on sent between sample ticks must be remembered.
        pulse(clk, note_on);
        check_gain(gain_out, 0, "held note-on");
        assert active_out = '0' severity failure;
        tick(clk, sample_tick); -- captures note-on; output gain remains 0
        check_gain(gain_out, 0, "note-on start gain");
        check_commit(gain_valid, "note-on commit");
        assert active_out = '1' severity failure;

        -- 3. Check exact *nonzero* gain latency: T, T+1, T+2.
        wait until falling_edge(clk);
        sample_tick <= '1';
        wait until rising_edge(clk); -- T
        wait for 1 ns;
        sample_tick <= '0';
        check_gain(gain_out, 0, "T should not publish yet");
        assert gain_valid = '0' severity failure;
        wait until rising_edge(clk); -- T+1
        wait for 1 ns;
        check_gain(gain_out, 0, "T+1 should not publish yet");
        assert gain_valid = '0' severity failure;
        wait until rising_edge(clk); -- T+2
        wait for 1 ns;
        check_gain(gain_out, 16383, "attack 1/4 at T+2");
        check_commit(gain_valid, "attack 1/4");

        -- 4. Remaining attack, decay and sustain values.
        tick(clk, sample_tick); check_gain(gain_out, 32767, "attack 2/4");
        tick(clk, sample_tick); check_gain(gain_out, 49151, "attack 3/4");
        tick(clk, sample_tick); check_gain(gain_out, 65535, "attack 4/4");
        tick(clk, sample_tick); check_gain(gain_out, 49152, "decay 1/2");
        tick(clk, sample_tick); check_gain(gain_out, 32768, "decay 2/2");
        tick(clk, sample_tick); check_gain(gain_out, 32768, "sustain hold");
        wait for 45 ns;
        check_gain(gain_out, 32768, "no sample tick holds gain");
        assert gain_valid = '0' and done_pulse = '0'
            report "gain_valid/done should be one-cycle pulses"
            severity failure;

        -- 5. Note-off initiates four-step release from held level.
        pulse(clk, note_off);
        tick(clk, sample_tick); check_gain(gain_out, 32768, "release event");
        tick(clk, sample_tick); check_gain(gain_out, 24576, "release 1/4");
        tick(clk, sample_tick); check_gain(gain_out, 16384, "release 2/4");
        tick(clk, sample_tick); check_gain(gain_out, 8192,  "release 3/4");
        tick(clk, sample_tick); check_gain(gain_out, 0,     "release 4/4");
        assert active_out = '0' and done_pulse = '1' and gain_valid = '1'
            report "release completion should align with final gain"
            severity failure;
        wait until rising_edge(clk);
        wait for 1 ns;
        assert done_pulse = '0' and gain_valid = '0'
            report "completion flags were not single-cycle pulses"
            severity failure;

        -- 6. Zero attack, decay and release: instant full gain/silence.
        attack_rate   <= (others => '0');
        decay_rate    <= (others => '0');
        sustain_level <= x"FFFF";
        release_rate  <= (others => '0');
        pulse(clk, note_on);
        tick(clk, sample_tick);
        check_gain(gain_out, 65535, "instant attack/decay");
        assert active_out = '1' severity failure;
        pulse(clk, note_off);
        tick(clk, sample_tick);
        check_gain(gain_out, 0, "instant release");
        assert active_out = '0' and done_pulse = '1' severity failure;

        -- 7. Sustain zero still represents an active note.
        sustain_level <= x"0000";
        pulse(clk, note_on);
        tick(clk, sample_tick);
        check_gain(gain_out, 0, "zero sustain");
        assert active_out = '1' severity failure;
        pulse(clk, note_off);
        tick(clk, sample_tick);
        assert active_out = '0' and done_pulse = '1' severity failure;

        -- 8. Note-off partway through attack: release uses current gain.
        attack_rate   <= x"40000000"; -- 4 ticks
        decay_rate    <= x"80000000"; -- 2 ticks
        sustain_level <= x"8000";
        release_rate  <= x"80000000"; -- 2 ticks
        pulse(clk, note_on);
        tick(clk, sample_tick);
        tick(clk, sample_tick);
        check_gain(gain_out, 16383, "partial attack");
        pulse(clk, note_off);
        tick(clk, sample_tick);
        check_gain(gain_out, 16383, "early release starts continuously");
        tick(clk, sample_tick);
        check_gain(gain_out, 8192, "early release halfway");

        -- 9. Retrigger during release from 8192, not from zero.
        attack_rate <= x"80000000"; -- 2 ticks
        pulse(clk, note_on);
        tick(clk, sample_tick);
        check_gain(gain_out, 8192, "retrigger level retained");
        assert active_out = '1' severity failure;
        tick(clk, sample_tick);
        check_gain(gain_out, 36863, "retrigger 1/2");
        tick(clk, sample_tick);
        check_gain(gain_out, 65535, "retrigger 2/2");

        -- 10. Parameter value must be captured at note-on, not at tick.
        rst <= '1';
        tick(clk, sample_tick);
        rst <= '0';
        attack_rate <= x"40000000";
        pulse(clk, note_on);
        attack_rate <= x"FFFFFFFF"; -- change input after event
        tick(clk, sample_tick);
        tick(clk, sample_tick);
        check_gain(gain_out, 16383, "atomic attack parameter");

        -- 11. Reset discards pending note events and pipeline contents.
        pulse(clk, note_on);
        rst <= '1';
        tick(clk, sample_tick);
        rst <= '0';
        tick(clk, sample_tick);
        check_gain(gain_out, 0, "reset discards pending event");
        assert active_out = '0' and done_pulse = '0' severity failure;

        -- 12. Longest supported phase: 65535 audio updates exactly.
        attack_rate   <= x"00000001"; -- clamps to the same supported minimum
        decay_rate    <= (others => '0');
        sustain_level <= x"FFFF";
        release_rate  <= (others => '0');
        pulse(clk, note_on);
        tick(clk, sample_tick);
        for i in 1 to 65534 loop
            tick(clk, sample_tick);
        end loop;
        assert gain_out < to_unsigned(65535, 16)
            report "longest attack finished too early" severity failure;
        tick(clk, sample_tick);
        check_gain(gain_out, 65535, "longest attack ends at tick 65535");

        -- Simultaneous on/off: on wins; latest pending event wins.
        attack_rate <= (others => '0'); decay_rate <= (others => '0');
        sustain_level <= to_unsigned(12345, 16);
        release_rate <= (others => '0');
        wait until falling_edge(clk);
        note_on <= '1'; note_off <= '1';
        wait until falling_edge(clk);
        note_on <= '0'; note_off <= '0';
        tick(clk, sample_tick);
        check_gain(gain_out, 12345, "simultaneous on/off gives note-on priority");
        assert active_out = '1' severity failure;
        pulse(clk, note_on); pulse(clk, note_off);
        tick(clk, sample_tick);
        check_gain(gain_out, 0, "latest off wins");
        assert active_out = '0' severity failure;
        pulse(clk, note_off); pulse(clk, note_on);
        tick(clk, sample_tick);
        check_gain(gain_out, 12345, "latest on wins");

        -- Event arriving while an older gain is in flight is retained.
        wait until falling_edge(clk); sample_tick <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        sample_tick <= '0';
        wait until falling_edge(clk); note_off <= '1';
        wait until rising_edge(clk); wait for 1 ns; note_off <= '0';
        wait until rising_edge(clk); wait for 1 ns;
        assert gain_valid = '1' and active_out = '1' severity failure;
        tick(clk, sample_tick);
        check_gain(gain_out, 0, "event during arithmetic was preserved");
        assert active_out = '0' and done_pulse = '1' severity failure;

        -- Reset before N+2 must discard an arithmetic job.
        pulse(clk, note_on);
        wait until falling_edge(clk); sample_tick <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        sample_tick <= '0'; rst <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        assert gain_out = 0 and gain_valid = '0' and active_out = '0' severity failure;
        wait until falling_edge(clk); rst <= '0';
        for i in 1 to 4 loop
            wait until rising_edge(clk); wait for 1 ns;
            assert gain_valid = '0' and gain_out = 0 severity failure;
        end loop;
        report "PASS: tb_adsr_envelope" severity note;
        std.env.stop;
        wait;
    end process;
end architecture sim;