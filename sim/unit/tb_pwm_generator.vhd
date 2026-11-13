-- Stage 01_AUDIO_TONE: self-checking PWM unit testbench.
-- Simulation only (VHDL-2008 for std.env.stop).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_pwm_generator is
end entity tb_pwm_generator;

architecture sim of tb_pwm_generator is
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz

    signal clk_i        : std_logic := '0';
    signal rst_i        : std_logic := '1';
    signal pcm_sample_i : signed(7 downto 0) := (others => '0');
    signal pwm_o        : std_logic;
begin
    clk_i <= not clk_i after CLK_PERIOD / 2;

    watchdog : process
    begin
        wait for 1 ms;
        assert false report "tb_pwm_generator timeout" severity failure;
    end process;

    dut : entity work.pwm_generator
        port map (
            clk_i        => clk_i,
            rst_i        => rst_i,
            pcm_sample_i => pcm_sample_i,
            pwm_o        => pwm_o
        );

    stimulus : process
        procedure check_duty(
            constant sample_value : in integer;
            constant expected_high_clocks : in natural
        ) is
            variable measured_high_clocks : natural := 0;
            variable transitions          : natural := 0;
            variable previous_pwm         : std_logic;
        begin
            pcm_sample_i <= to_signed(sample_value, pcm_sample_i'length);

            -- Give the input at least two whole PWM periods to be latched.
            for i in 1 to 512 loop
                wait until rising_edge(clk_i);
            end loop;

            -- Count over exactly one 256-clock carrier period.
            -- Also verify its expected number of PWM transitions.
            wait until falling_edge(clk_i);
            previous_pwm := pwm_o;
            for i in 1 to 256 loop
                wait until falling_edge(clk_i);
                assert (pwm_o = '0' or pwm_o = '1')
                    report "PWM output is not binary"
                    severity failure;
                if pwm_o /= previous_pwm then
                    transitions := transitions + 1;
                end if;
                previous_pwm := pwm_o;
                if pwm_o = '1' then
                    measured_high_clocks := measured_high_clocks + 1;
                end if;
            end loop;

            if expected_high_clocks = 0 then
                assert transitions = 0
                    report "Zero-duty PWM must have no transitions"
                    severity failure;
            else
                assert transitions = 2
                    report "Nonzero PWM must have 2 transitions per period"
                    severity failure;
            end if;

            assert measured_high_clocks = expected_high_clocks
                report "Incorrect duty for PCM=" & integer'image(sample_value) &
                       ": measured=" & integer'image(measured_high_clocks) &
                       ", expected=" & integer'image(expected_high_clocks)
                severity failure;

            report "PASS: PCM=" & integer'image(sample_value) &
                   ", high clocks=" & integer'image(measured_high_clocks)
                severity note;
        end procedure;
    begin
        -- Initial reset: the PWM counter and duty register are initialized.
        rst_i <= '1';
        wait for 30 ns;
        assert pwm_o = '1'
            report "PWM reset did not initialize its midpoint duty"
            severity failure;

        wait until falling_edge(clk_i);
        rst_i <= '0';

        -- Expected high clocks per 256: sample_value + 128.
        check_duty(-128,   0);   -- 0% duty
        check_duty( -64,  64);   -- 25% duty
        check_duty( -32,  96);   -- 37.5% duty
        check_duty(   0, 128);   -- 50% duty (signed silence)
        check_duty(  32, 160);   -- 62.5% duty
        check_duty(  64, 192);   -- 75% duty
        check_duty( 127, 255);   -- 255/256 duty

        -- A mid-period PCM change must not change the current duty register.
        wait until falling_edge(clk_i);
        rst_i <= '1';
        wait until rising_edge(clk_i);
        wait for 1 ns;
        wait until falling_edge(clk_i);
        rst_i <= '0';
        pcm_sample_i <= to_signed(127, 8);
        for n in 1 to 256 loop
            wait until rising_edge(clk_i);
            wait for 1 ns;
            if n < 128 then
                assert pwm_o = '1' severity failure;
            else
                assert pwm_o = '0'
                    report "PWM duty changed before the period boundary" severity failure;
            end if;
            wait until falling_edge(clk_i);
            if n = 64 then pcm_sample_i <= to_signed(-128, 8); end if;
        end loop;
        -- At the boundary the most recent sample (-128) was latched.
        pcm_sample_i <= to_signed(127, 8);
        for n in 1 to 256 loop
            wait until rising_edge(clk_i);
            wait for 1 ns;
            if n < 256 then
                assert pwm_o = '0' severity failure;
            else
                assert pwm_o = '1'
                    report "PWM did not latch new duty at boundary" severity failure;
            end if;
        end loop;

        report "PASS: tb_pwm_generator" severity note;
        std.env.stop;
        wait;
    end process;
end architecture sim;
