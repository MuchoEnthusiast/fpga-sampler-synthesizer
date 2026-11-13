library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audio_pkg.all;

-- Portable monophonic live sampler. Recording owns the RAM write port and
-- mutes/reset-flushes playback. A completed clip is published only after its
-- final write. Every playback tick, including silence, advances the effects.
-- Preserved Stage05 ADSR: tick N -> gain_valid N+2. PCM output after N+9.
-- Sample ticks must be at least 16 clocks apart; the board uses 6250.
entity sampler_core is
    generic (
        ADDR_BITS : positive := 14;
        SAMPLE_COUNT : positive := 16000;
        INIT_FILE : string := "";
        PRELOADED_SAMPLES : natural := 0;
        ECHO_DELAY_SAMPLES : positive := 4096;
        ATTACK_RATE_G : unsigned(31 downto 0) := x"0199999A";
        DECAY_RATE_G : unsigned(31 downto 0) := x"0028F5C3";
        SUSTAIN_G : unsigned(15 downto 0) := x"8000";
        RELEASE_RATE_G : unsigned(31 downto 0) := x"001C71C8"
    );
    port (
        clk, rst, sample_tick : in std_logic;
        note_on, note_off : in std_logic;
        note_number, velocity : in std_logic_vector(6 downto 0);
        linear_mode, distortion_enable, distortion_drive4, echo_enable : in std_logic;
        pcm_out : out pcm8_t;
        pcm_valid : out std_logic;
        current_note : out std_logic_vector(6 downto 0);
        note_held, envelope_active, player_ready, stream_error : out std_logic;
        record_start, record_stop, record_pcm_valid : in std_logic := '0';
        record_pcm : in pcm8_t := (others => '0');
        sustain_pedal, panic : in std_logic := '0';
        volume_shift : in unsigned(1 downto 0) := (others => '0');
        recording, sample_ready, record_done : out std_logic := '0';
        sample_length, recorded_count : out unsigned(ADDR_BITS downto 0) := (others => '0')
    );
end entity;

architecture rtl of sampler_core is
    signal step : unsigned(17 downto 0);
    signal vel, transaction_vel : unsigned(6 downto 0) := (others => '0');
    signal held, start_note, release_note, active, voice_play, voice_rst, audio_rst : std_logic;
    signal rd_addr, wr_addr : unsigned(ADDR_BITS - 1 downto 0) := (others => '0');
    signal wr_en, recording_s, sample_ready_s : std_logic := '0';
    signal length_s : unsigned(ADDR_BITS downto 0) := (others => '0');
    signal wr_data, rd_data, raw_pcm, transaction_pcm, gain_pcm, fx_pcm : pcm8_t := (others => '0');
    signal raw_valid, ready, env_valid, gain_valid, fx_valid : std_logic;
    signal env_gain : unsigned(15 downto 0);
    signal echo_pcm : pcm16_t;
    signal echo_valid, echo_ready : std_logic;
    signal capture_pending, expect_raw, busy, error_q : std_logic := '0';
    signal warmup_q : std_logic := '1';
    signal fx_enable_q, fx_drive_q, echo_enable_q : std_logic := '0';
    signal volume_q : unsigned(1 downto 0) := (others => '0');
    signal output_q : pcm8_t := (others => '0');
    signal output_valid_q : std_logic := '0';
begin
    assert PRELOADED_SAMPLES = 0 or INIT_FILE /= ""
        report "Preloaded sample metadata requires an initialization file" severity failure;
    audio_rst <= rst or recording_s or record_start or panic or not sample_ready_s;
    voice_rst <= audio_rst or start_note;
    voice_play <= held or active;
    note_held <= held;
    envelope_active <= active;
    player_ready <= ready;
    stream_error <= error_q;
    pcm_out <= output_q;
    pcm_valid <= output_valid_q;
    recording <= recording_s;
    sample_ready <= sample_ready_s;
    sample_length <= length_s;

    u_recorder : entity work.record_controller
        generic map (ADDR_BITS => ADDR_BITS, MAX_SAMPLES => SAMPLE_COUNT,
                     PRELOADED_SAMPLES => PRELOADED_SAMPLES)
        port map (clk => clk, rst => rst, record_start => record_start,
                  record_stop => record_stop, sample_valid => record_pcm_valid,
                  sample_data => record_pcm, wr_en => wr_en, wr_addr => wr_addr,
                  wr_data => wr_data, recording => recording_s,
                  sample_ready => sample_ready_s, record_done => record_done,
                  sample_length => length_s, recorded_count => recorded_count);

    u_notes : entity work.note_event_manager
        port map (clk, audio_rst, note_on, note_off, note_number, velocity,
                  current_note, vel, step, held, start_note, release_note,
                  sustain_pedal, panic);

    u_ram : entity work.sample_ram
        generic map (ADDR_BITS => ADDR_BITS, INIT_FILE => INIT_FILE)
        port map (clk_i => clk, wr_en_i => wr_en, wr_addr_i => wr_addr,
                  wr_data_i => wr_data, rd_addr_i => rd_addr, rd_data_o => rd_data);

    u_player : entity work.sample_player
        generic map (ADDR_BITS => ADDR_BITS, FRAC_BITS => 16, SAMPLE_COUNT => SAMPLE_COUNT)
        port map (clk_i => clk, rst_i => voice_rst, play_i => voice_play,
                  sample_tick_i => sample_tick, step_i => step, linear_mode_i => linear_mode,
                  rd_addr_o => rd_addr, rd_data_i => rd_data, phase_frac_o => open,
                  pcm_o => raw_pcm, pcm_valid_o => raw_valid, ready_o => ready,
                  sample_length_i => length_s);

    -- This is the uploaded, validated Stage05 pipeline; its RTL is preserved.
    u_envelope : entity work.adsr_envelope
        port map (clk => clk, rst => audio_rst, sample_tick => sample_tick,
                  note_on => start_note, note_off => release_note,
                  attack_rate => ATTACK_RATE_G, decay_rate => DECAY_RATE_G,
                  sustain_level => SUSTAIN_G, release_rate => RELEASE_RATE_G,
                  gain_out => env_gain, active_out => active, done_pulse => open,
                  gain_valid => env_valid);

    -- PCM captured N+1; ADSR publishes N+2; gain consumes both at N+3.
    u_gain : entity work.audio_gain
        port map (clk, audio_rst, transaction_pcm, env_gain, transaction_vel,
                  env_valid, gain_pcm, gain_valid);
    u_distortion : entity work.distortion
        port map (clk, audio_rst, gain_valid, gain_pcm, fx_enable_q, fx_drive_q,
                  fx_pcm, fx_valid);
    u_echo : entity work.delay_effect
        generic map (G_DELAY_SAMPLES => ECHO_DELAY_SAMPLES)
        port map (clk, audio_rst, fx_valid, echo_ready, widen_pcm(fx_pcm),
                  echo_enable_q, echo_valid, echo_pcm);

    process(clk)
    begin
        if rising_edge(clk) then
            if audio_rst = '1' then
                capture_pending <= '0'; expect_raw <= '0'; busy <= '0';
                warmup_q <= '1';
                transaction_pcm <= (others => '0'); transaction_vel <= (others => '0');
                fx_enable_q <= '0'; fx_drive_q <= '0'; echo_enable_q <= '0';
                volume_q <= (others => '0');
                output_q <= (others => '0'); output_valid_q <= '0';
            else
                output_valid_q <= '0';
                capture_pending <= '0';
                if start_note = '1' then warmup_q <= '1';
                elsif ready = '1' then warmup_q <= '0'; end if;
                if sample_tick = '1' then
                    busy <= '1'; capture_pending <= '1';
                    transaction_pcm <= (others => '0'); transaction_vel <= vel;
                    fx_enable_q <= distortion_enable; fx_drive_q <= distortion_drive4;
                    echo_enable_q <= echo_enable; volume_q <= volume_shift;
                    expect_raw <= voice_play and ready and not start_note;
                elsif capture_pending = '1' and expect_raw = '1' then
                    if raw_valid = '1' then transaction_pcm <= raw_pcm; end if;
                end if;
                if echo_valid = '1' then
                    output_q <= narrow_pcm(shift_right(echo_pcm, to_integer(volume_q)));
                    output_valid_q <= '1'; busy <= '0';
                end if;
            end if;
            -- Diagnostics survive note changes/recording; only user reset clears.
            if rst = '1' then error_q <= '0';
            elsif audio_rst = '0' then
                if sample_tick = '1' then
                    if busy = '1' then error_q <= '1'; end if;
                    if voice_play = '1' and ready = '0' and start_note = '0' and warmup_q = '0' then
                        error_q <= '1';
                    end if;
                elsif capture_pending = '1' and expect_raw = '1' and raw_valid = '0' then
                    error_q <= '1';
                end if;
                if fx_valid = '1' and echo_ready = '0' then error_q <= '1'; end if;
            end if;
        end if;
    end process;
end architecture;
