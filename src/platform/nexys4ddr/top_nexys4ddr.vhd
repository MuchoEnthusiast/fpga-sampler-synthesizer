library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.audio_pkg.all;

-- Nexys 4 DDR physical boundary. Internal logic uses only CLK100MHZ.
-- CPU_RESETN/BTNC reset; BTNL starts recording; BTND stops/panics;
-- hold BTNU to audition the stored sample at its original/root pitch.
entity top_nexys4ddr is
    generic (
        UART_CLKS_PER_BIT : positive := 868;
        AUDIO_TICK_DIVIDER : positive := 6250;
        ADDR_BITS : positive := 14;
        SAMPLE_COUNT : positive := 16000;
        INIT_FILE : string := "";
        PRELOADED_SAMPLES : natural := 0;
        ECHO_DELAY_SAMPLES : positive := 4096;
        MIC_HALF_PERIOD_CYCLES : positive := 25;
        MIC_WARMUP_CYCLES : natural := 5000000;
        MIC_DECIMATION : positive := 125;
        MIC_PCM_SHIFT : positive := 12;
        DEBOUNCE_CYCLES : positive := 500000;
        ATTACK_RATE_G : unsigned(31 downto 0) := x"0199999A";
        DECAY_RATE_G : unsigned(31 downto 0) := x"0028F5C3";
        SUSTAIN_G : unsigned(15 downto 0) := x"8000";
        RELEASE_RATE_G : unsigned(31 downto 0) := x"001C71C8"
    );
    port (
        CLK100MHZ, CPU_RESETN, BTNC, BTNL, BTNU, BTND, UART_TXD_IN : in std_logic;
        SW0, SW1, SW2, SW3, SW4, SW5 : in std_logic;
        M_DATA : in std_logic;
        M_CLK, M_LRSEL : out std_logic;
        LED : out std_logic_vector(15 downto 0);
        AUD_PWM, AUD_SD : out std_logic
    );
end entity;

architecture rtl of top_nexys4ddr is
    signal controls : std_logic_vector(10 downto 0);
    signal rst, tick, rx_valid, rx_error, uart_on, uart_off, note_on, note_off : std_logic;
    signal byte_data : std_logic_vector(7 downto 0);
    signal uart_note, uart_velocity, note_number, velocity, current_note : std_logic_vector(6 downto 0);
    signal sustain, uart_panic, panic : std_logic;
    signal record_press, stop_press, audition_press, audition_level, audition_previous : std_logic := '0';
    signal audition_release, record_request, arbiter_reset : std_logic;
    signal held, active, ready, stream_error, pwm : std_logic;
    signal error_sticky, clip_sticky : std_logic := '0';
    signal recording, sample_ready, record_done : std_logic;
    signal capture_ready, filter_ready, microphone_ready, pdm_bit, pdm_valid : std_logic;
    signal filter_valid, dc_valid, filter_clip, dc_clip : std_logic;
    signal filter_pcm, mic_pcm, pcm : pcm8_t;
begin
    assert AUDIO_TICK_DIVIDER >= 16
        report "Audio pipeline needs at least16 system clocks per sample" severity failure;
    assert AUDIO_TICK_DIVIDER = 2 * MIC_HALF_PERIOD_CYCLES * MIC_DECIMATION
        report "Capture and playback must use the same audio sample rate" severity failure;
    u_inputs : entity work.input_synchronizer
        generic map (WIDTH => 11)
        port map (CLK100MHZ, CPU_RESETN & BTNC & BTNL & BTNU & BTND &
                  SW5 & SW4 & SW3 & SW2 & SW1 & SW0, controls);
    rst <= not controls(10) or controls(9);
    u_record_button : entity work.button_debouncer
        generic map (STABLE_CYCLES => DEBOUNCE_CYCLES)
        port map (CLK100MHZ, rst, controls(8), open, record_press);
    u_audition_button : entity work.button_debouncer
        generic map (STABLE_CYCLES => DEBOUNCE_CYCLES)
        port map (CLK100MHZ, rst, controls(7), audition_level, audition_press);
    u_stop_button : entity work.button_debouncer
        generic map (STABLE_CYCLES => DEBOUNCE_CYCLES)
        port map (CLK100MHZ, rst, controls(6), open, stop_press);
    audition_release <= audition_previous and not audition_level;
    record_request <= record_press and microphone_ready;
    panic <= uart_panic or stop_press;

    u_tick : entity work.sample_tick_generator
        generic map (DIVIDER => AUDIO_TICK_DIVIDER)
        port map (CLK100MHZ, rst, tick);
    u_mic_capture : entity work.pdm_capture
        generic map (G_HALF_PERIOD_CYCLES => MIC_HALF_PERIOD_CYCLES,
                     G_WARMUP_CYCLES => MIC_WARMUP_CYCLES)
        port map (CLK100MHZ, rst, M_DATA, M_CLK, M_LRSEL, capture_ready, pdm_bit, pdm_valid);
    u_mic_filter : entity work.pdm_decimator
        generic map (G_DECIMATION => MIC_DECIMATION, G_SHIFT => MIC_PCM_SHIFT)
        port map (CLK100MHZ, rst, pdm_bit, pdm_valid, filter_pcm, filter_valid,
                  filter_ready, filter_clip);
    u_mic_dc : entity work.dc_blocker
        port map (CLK100MHZ, rst, filter_valid, filter_pcm, mic_pcm, dc_valid, dc_clip);
    microphone_ready <= capture_ready and filter_ready;

    u_uart : entity work.uart_rx
        generic map (CLKS_PER_BIT => UART_CLKS_PER_BIT)
        port map (CLK100MHZ, rst, UART_TXD_IN, byte_data, rx_valid, rx_error);
    u_decoder : entity work.note_command_decoder
        port map (CLK100MHZ, rst, byte_data, rx_valid, rx_error,
                  uart_on, uart_off, uart_note, uart_velocity, sustain, uart_panic);
    -- Ownership prevents a coincident unrelated UART off from dropping a
    -- button release, and prevents an old button release from stopping a
    -- newer UART note. Reset clears ownership without replaying held buttons.
    arbiter_reset <= rst or panic or record_request or recording or not sample_ready;
    u_note_arbiter : entity work.note_input_arbiter
        port map (clk => CLK100MHZ, rst => arbiter_reset,
                  uart_note_on => uart_on, uart_note_off => uart_off,
                  uart_note_number => uart_note, uart_velocity => uart_velocity,
                  audition_press => audition_press, audition_release => audition_release,
                  note_on => note_on, note_off => note_off,
                  note_number => note_number, velocity => velocity,
                  audition_owns_voice => open);
    u_sampler : entity work.sampler_core
        generic map (ADDR_BITS => ADDR_BITS, SAMPLE_COUNT => SAMPLE_COUNT, INIT_FILE => INIT_FILE,
                     PRELOADED_SAMPLES => PRELOADED_SAMPLES,
                     ECHO_DELAY_SAMPLES => ECHO_DELAY_SAMPLES, ATTACK_RATE_G => ATTACK_RATE_G,
                     DECAY_RATE_G => DECAY_RATE_G, SUSTAIN_G => SUSTAIN_G,
                     RELEASE_RATE_G => RELEASE_RATE_G)
        port map (clk => CLK100MHZ, rst => rst, sample_tick => tick,
                  note_on => note_on, note_off => note_off, note_number => note_number,
                  velocity => velocity, linear_mode => controls(2),
                  distortion_enable => controls(3), distortion_drive4 => controls(4),
                  echo_enable => controls(5), pcm_out => pcm, pcm_valid => open,
                  current_note => current_note, note_held => held,
                  envelope_active => active, player_ready => ready, stream_error => stream_error,
                  record_start => record_request, record_stop => stop_press,
                  record_pcm_valid => dc_valid, record_pcm => mic_pcm,
                  sustain_pedal => sustain, panic => panic,
                  volume_shift => unsigned(controls(1 downto 0)),
                  recording => recording, sample_ready => sample_ready, record_done => record_done,
                  sample_length => open, recorded_count => open);
    u_pwm : entity work.pwm_generator
        port map (CLK100MHZ, rst, pcm, pwm);
    AUD_PWM <= '0' when pwm = '0' else 'Z';
    AUD_SD <= not rst;

    process(CLK100MHZ)
    begin
        if rising_edge(CLK100MHZ) then
            if rst = '1' then
                error_sticky <= '0'; clip_sticky <= '0'; audition_previous <= '0';
            else
                audition_previous <= audition_level;
                if rx_error = '1' then error_sticky <= '1'; end if;
                if record_request = '1' then clip_sticky <= '0';
                elsif filter_clip = '1' or dc_clip = '1' then clip_sticky <= '1'; end if;
            end if;
        end if;
    end process;
    LED(0) <= microphone_ready;
    LED(1) <= recording;
    LED(2) <= sample_ready;
    LED(3) <= held;
    LED(4) <= active;
    LED(5) <= ready;
    LED(6) <= stream_error;
    LED(7) <= error_sticky;
    LED(8) <= clip_sticky;
    LED(15 downto 9) <= current_note;
end architecture;
