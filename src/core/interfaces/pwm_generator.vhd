-- Reusable 8-bit PWM audio output. Migrated from Stage 01.
-- Synthesizable, board-independent RTL.
--
-- Interface:
--   clk_i        : 100 MHz in this experiment
--   rst_i        : synchronous, active-high reset
--   pcm_sample_i : signed two's-complement PCM [-128, 127]
--   pwm_o        : logical PWM bit (NOT an open-drain pin driver)
--
-- Duty cycle = (signed PCM + 128) / 256.
-- New PCM values are latched only at PWM period boundaries.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity pwm_generator is
    port (
        clk_i        : in  std_logic;
        rst_i        : in  std_logic;
        pcm_sample_i : in  signed(7 downto 0);
        pwm_o        : out std_logic
    );
end entity pwm_generator;

architecture rtl of pwm_generator is
    constant PWM_MAX : unsigned(7 downto 0) := (others => '1');
    constant PCM_ZERO_DUTY : unsigned(7 downto 0) := to_unsigned(128, 8);

    signal carrier_count : unsigned(7 downto 0) := (others => '0');
    signal duty_count    : unsigned(7 downto 0) := PCM_ZERO_DUTY;
begin
    process (clk_i)
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                carrier_count <= (others => '0');
                duty_count    <= PCM_ZERO_DUTY;
            elsif carrier_count = PWM_MAX then
                carrier_count <= (others => '0');

                -- Flip the sign bit: 8-bit signed PCM -> offset binary.
                -- -128 -> 0, 0 -> 128, +127 -> 255.
                duty_count <= unsigned(std_logic_vector(pcm_sample_i) xor x"80");
            else
                carrier_count <= carrier_count + 1;
            end if;
        end if;
    end process;

    -- At 100 MHz: carrier = 100,000,000 / 256 = 390,625 Hz.
    -- This is LOGICAL push-pull PWM. The board-specific top-level
    -- converts logical '1' into high impedance for AUD_PWM.
    pwm_o <= '1' when carrier_count < duty_count else '0';
end architecture rtl;
