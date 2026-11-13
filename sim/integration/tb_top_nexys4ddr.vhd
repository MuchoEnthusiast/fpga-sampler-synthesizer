library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

-- Full board path with a physical PDM input model. Microphone and audio rates
-- remain real: 2 MHz PDM, 16 kHz PCM, 100 MHz system clock. Only UART, button
-- debounce and microphone startup are accelerated; storage is a 32-sample clip.
entity tb_top_nexys4ddr is end entity;
architecture sim of tb_top_nexys4ddr is
    constant CLOCK_PERIOD : time := 10 ns;
    constant BIT_TIME : time := 160 ns;
    constant AUDIO_PERIOD : time := 62500 ns;
    signal clk : std_logic := '0';
    signal reset_n, reset_button, record_button, audition_button, stop_button : std_logic := '0';
    signal uart_line : std_logic := '1';
    signal sw0, sw1, sw3, sw4, sw5 : std_logic := '0';
    signal sw2 : std_logic := '1';
    signal microphone_data : std_logic := '0';
    signal microphone_clock, microphone_lrsel : std_logic;
    signal led : std_logic_vector(15 downto 0);
    signal audio_pad, audio_enable : std_logic;
begin
    clk <= not clk after CLOCK_PERIOD/2;
    -- Board analog pull-up resolves a released pin to H. A push-pull '1'
    -- would resolve to '1' and fail the continuous electrical-model check.
    audio_pad <= 'H';
    dut : entity work.top_nexys4ddr
        generic map (
            UART_CLKS_PER_BIT => 16, AUDIO_TICK_DIVIDER => 6250,
            ADDR_BITS => 5, SAMPLE_COUNT => 32, INIT_FILE => "", PRELOADED_SAMPLES => 0,
            ECHO_DELAY_SAMPLES => 4, MIC_HALF_PERIOD_CYCLES => 25,
            MIC_WARMUP_CYCLES => 100, MIC_DECIMATION => 125, MIC_PCM_SHIFT => 12,
            DEBOUNCE_CYCLES => 2,
            ATTACK_RATE_G => x"00000000", DECAY_RATE_G => x"00000000",
            SUSTAIN_G => x"8000", RELEASE_RATE_G => x"00000000"
        )
        port map (
            CLK100MHZ => clk, CPU_RESETN => reset_n, BTNC => reset_button,
            BTNL => record_button, BTNU => audition_button, BTND => stop_button,
            UART_TXD_IN => uart_line,
            SW0 => sw0, SW1 => sw1, SW2 => sw2, SW3 => sw3, SW4 => sw4, SW5 => sw5,
            M_DATA => microphone_data, M_CLK => microphone_clock, M_LRSEL => microphone_lrsel,
            LED => led, AUD_PWM => audio_pad, AUD_SD => audio_enable
        );

    -- First-order pulse-density encoding: alternate 3/8 and 5/8 density
    -- every 500 PDM bits, a 2 kHz bipolar waveform. Change data on falling
    -- microphone edges so it is stable around the next capture/rising edge.
    microphone : process
        variable accumulator : natural range 0 to 15 := 0;
        variable bit_count : natural range 0 to 999 := 0;
        variable density : natural;
    begin
        wait until falling_edge(microphone_clock);
        if reset_n = '0' or reset_button = '1' then
            accumulator := 0; bit_count := 0; microphone_data <= '0';
        else
            if bit_count < 500 then density := 3; else density := 5; end if;
            accumulator := accumulator + density;
            if accumulator >= 8 then
                accumulator := accumulator - 8; microphone_data <= '1';
            else
                microphone_data <= '0';
            end if;
            if bit_count = 999 then bit_count := 0;
            else bit_count := bit_count + 1; end if;
        end if;
    end process;

    invariants : process
    begin
        wait until falling_edge(clk);
        assert audio_pad = '0' or audio_pad = 'H'
            report "AUD_PWM must resolve to low or the external pull-up" severity failure;
        assert microphone_lrsel = '0' report "Microphone channel/edge changed" severity failure;
        assert not (led(1) = '1' and led(2) = '1')
            report "A recording clip was published before commit" severity failure;
        if reset_n = '1' and reset_button = '0' then
            assert led(6) = '0' report "Board path raised stream_error" severity failure;
        end if;
    end process;

    stimulus : process
        procedure send_byte(value : std_logic_vector(7 downto 0); good_stop : boolean := true) is
        begin
            uart_line <= '0'; wait for BIT_TIME;
            for i in 0 to 7 loop
                uart_line <= value(i); wait for BIT_TIME;
            end loop;
            if good_stop then uart_line <= '1'; else uart_line <= '0'; end if;
            wait for BIT_TIME; uart_line <= '1'; wait for BIT_TIME;
        end procedure;
        procedure command(status : std_logic_vector(7 downto 0); first, second : natural) is
        begin
            send_byte(status);
            send_byte(std_logic_vector(to_unsigned(first, 8)));
            send_byte(std_logic_vector(to_unsigned(second, 8)));
        end procedure;
        procedure press(signal button : out std_logic) is
        begin
            wait until falling_edge(clk); button <= '1';
            wait for 150 ns; button <= '0';
            wait for 150 ns;
        end procedure;
        procedure await_led(index : natural; value : std_logic; limit : time;
                            label_text : string) is
        begin
            if led(index) /= value then
                wait until led(index) = value for limit;
            end if;
            assert led(index) = value report label_text severity failure;
            wait for 1 ns;
        end procedure;
        procedure pwm_window(variable highs : out natural) is
        begin
            highs := 0;
            for i in 1 to 256 loop
                wait until rising_edge(clk); wait for 1 ns;
                if audio_pad = 'H' then highs := highs + 1; end if;
            end loop;
        end procedure;
        procedure silence is
            variable highs : natural;
        begin
            -- Allow two PWM period boundaries after a PCM change.
            wait for 6 us;
            for frame in 1 to 3 loop
                pwm_window(highs);
                assert highs = 128 report "Expected signed-zero/50-percent PWM silence" severity failure;
            end loop;
        end procedure;
        procedure audible is
            variable highs : natural;
            variable changed : boolean := false;
        begin
            -- A complete 2 kHz source cycle is covered even if the first
            -- captured value is zero or a note event waits for the next tick.
            for frame in 1 to 256 loop
                pwm_window(highs);
                if highs /= 128 then changed := true; end if;
            end loop;
            assert changed report "Recorded microphone clip produced no nonzero audio" severity failure;
        end procedure;
        variable started, edge_time : time;
    begin
        wait for 100 ns;
        assert audio_enable = '0' and led(2) = '0' severity failure;
        reset_n <= '1';
        wait until rising_edge(microphone_clock); edge_time := now;
        wait until falling_edge(microphone_clock);
        assert now-edge_time = 250 ns report "Incorrect microphone high half-period" severity failure;
        edge_time := now;
        wait until rising_edge(microphone_clock);
        assert now-edge_time = 250 ns report "Incorrect microphone low half-period" severity failure;
        await_led(0, '1', 1 ms, "Microphone never became ready after filter fill");
        assert audio_enable = '1' and led(2) = '0' severity failure;
        silence;
        command(x"90", 69, 127); wait for 2*AUDIO_PERIOD;
        assert led(3) = '0' and led(4) = '0'
            report "An empty sample buffer accepted a note" severity failure;
        silence;

        -- Automatic full recording: clip metadata becomes valid only at end.
        started := now; press(record_button);
        await_led(1, '1', 5 us, "Record button did not start capture");
        assert led(2) = '0' and led(3) = '0' and led(4) = '0' severity failure;
        await_led(2, '1', 3 ms, "Full recording never committed");
        assert led(1) = '0' severity failure;
        assert now-started >= 31*AUDIO_PERIOD and now-started <= 33*AUDIO_PERIOD
            report "Full clip duration does not match 32 microphone samples" severity failure;
        silence; -- recording does not start an unsolicited note

        command(x"90", 69, 127);
        await_led(3, '1', 10 us, "UART note did not start");
        await_led(4, '1', 2*AUDIO_PERIOD, "ADSR note did not commit");
        assert unsigned(led(15 downto 9)) = 69 severity failure;
        audible;
        command(x"90", 81, 64); wait for 2*AUDIO_PERIOD;
        assert unsigned(led(15 downto 9)) = 81 and led(3) = '1' severity failure;
        audible;
        command(x"80", 69, 0); wait for AUDIO_PERIOD;
        assert led(3) = '1' report "Wrong-note off stopped the current octave note" severity failure;

        command(x"B0", 64, 127);
        command(x"80", 81, 0); wait for 2*AUDIO_PERIOD;
        assert led(3) = '1' and led(4) = '1'
            report "Sustain did not hold the released key" severity failure;
        command(x"B0", 64, 0);
        await_led(3, '0', 10 us, "Pedal-up did not release the gate");
        await_led(4, '0', 2*AUDIO_PERIOD, "Pedal-up did not finish zero-duration release");
        silence;

        -- Panic must stop a pedal-held note and clear a populated echo tail.
        sw5 <= '1';
        command(x"B0", 64, 127); command(x"90", 69, 127);
        await_led(4, '1', 2*AUDIO_PERIOD, "Panic setup note failed");
        wait for 6*AUDIO_PERIOD;
        command(x"80", 69, 0); wait for AUDIO_PERIOD;
        assert led(3) = '1' severity failure;
        command(x"B0", 120, 0);
        await_led(3, '0', 10 us, "Panic did not clear the note gate");
        await_led(4, '0', 10 us, "Panic did not clear ADSR state");
        assert led(2) = '1' report "Panic destroyed recorded metadata" severity failure;
        silence;

        -- Standalone audition and physical stop without the PC keyboard.
        sw3 <= '1'; sw4 <= '1';
        audition_button <= '1';
        await_led(3, '1', 10 us, "Audition button did not trigger a note");
        assert unsigned(led(15 downto 9)) = 69 severity failure;
        audible;
        -- UART takes over the same pitch while the local button is held.
        -- Releasing that old button must not terminate the newer UART voice.
        command(x"90", 69, 127); wait for AUDIO_PERIOD;
        audition_button <= '0'; wait for 2*AUDIO_PERIOD;
        assert led(3) = '1' and led(4) = '1'
            report "Stale audition release stopped the newer UART root note" severity failure;
        command(x"80", 69, 0);
        await_led(3, '0', 10 us, "UART-owned root note did not release");
        await_led(4, '0', 2*AUDIO_PERIOD, "UART-owned envelope did not release");
        audition_button <= '1';
        await_led(3, '1', 10 us, "Audition could not regain ownership");
        press(stop_button);
        await_led(3, '0', 10 us, "Physical stop did not panic");
        silence;
        assert led(3) = '0' report "Held audition button retriggered after stop" severity failure;
        audition_button <= '0'; wait for 1 us;
        sw3 <= '0'; sw4 <= '0'; sw5 <= '0';

        -- Replace the clip with a shorter manual recording (at least5samples).
        press(record_button);
        await_led(1, '1', 5 us, "Re-record did not start");
        assert led(2) = '0' report "Old clip remained published during replacement" severity failure;
        wait for 6*AUDIO_PERIOD;
        assert led(1) = '1' report "Short clip ended before explicit stop" severity failure;
        press(stop_button);
        await_led(2, '1', 10 us, "Manual recording did not commit a valid shorter clip");
        assert led(1) = '0' severity failure;
        audition_button <= '1';
        await_led(3, '1', 10 us, "Short clip audition did not start");
        audible;
        audition_button <= '0';
        await_led(3, '0', 10 us, "Audition release did not end note");
        await_led(4, '0', 2*AUDIO_PERIOD, "Audition release did not finish envelope");
        silence;

        -- Abort before four samples: stale RAM must not become a valid clip.
        press(record_button); press(stop_button); wait for 2 us;
        assert led(1) = '0' and led(2) = '0' severity failure;
        command(x"90", 69, 127); wait for AUDIO_PERIOD;
        assert led(3) = '0' severity failure;
        silence;
        send_byte(x"90", false); wait for 2 us;
        assert led(7) = '1' report "Framing error indication was not latched" severity failure;
        command(x"80", 69, 0);
        assert led(7) = '1' report "Framing diagnostic did not remain sticky" severity failure;
        reset_button <= '1'; wait for 150 ns;
        assert audio_enable = '0' and led(7) = '0' and led(2) = '0' severity failure;
        reset_button <= '0';
        await_led(0, '1', 1 ms, "Microphone failed to restart after reset");
        assert audio_enable = '1' and led(2) = '0' and led(6) = '0' severity failure;
        silence;
        report "PASS: tb_top_nexys4ddr" severity note;
        stop; wait;
    end process;
    watchdog : process
    begin
        wait for 20 ms;
        assert false report "tb_top_nexys4ddr timeout" severity failure;
    end process;
end architecture;
