-- Preserved Stage 07 numeric contract: floor(pcm * gain * vc / 2^23).
-- vc=128 when velocity=127, otherwise vc=velocity. gain=65535 is
-- nominal full scale (65535/65536), not mathematically exact unity.
-- Arithmetic right shift rounds negative values toward minus infinity.
-- Input accepted at N -> output valid after N+2; one input per clock.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_gain is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;

        pcm_i       : in  signed(7 downto 0);
        gain_i      : in  unsigned(15 downto 0);
        velocity_i  : in  unsigned(6 downto 0);
        in_valid_i  : in  std_logic;

        pcm_o       : out signed(7 downto 0);
        out_valid_o : out std_logic
    );
end entity;

architecture rtl of audio_gain is

    -- 8 x 17 = 25 signed bits.
    signal env_product_q : signed(24 downto 0)
                           := (others => '0');

    -- Velocity is represented as a nonnegative 9-bit
    -- signed number. Maximum coefficient = 128.
    signal velocity_q : signed(8 downto 0)
                        := (others => '0');

    -- 25 x 9 = 34 signed bits.
    signal final_product_q : signed(33 downto 0)
                             := (others => '0');

    signal valid_1_q : std_logic := '0';
    signal valid_2_q : std_logic := '0';

    signal pcm_q   : signed(7 downto 0) := (others => '0');
    signal valid_q : std_logic := '0';

begin

    process(clk)
        variable scaled : signed(33 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                env_product_q   <= (others => '0');
                final_product_q <= (others => '0');
                velocity_q      <= (others => '0');
                valid_1_q       <= '0';
                valid_2_q       <= '0';
                pcm_q           <= (others => '0');
                valid_q         <= '0';
            else
                -- Stage A: PCM multiplied by ADSR gain.
                valid_1_q <= in_valid_i;

                if in_valid_i = '1' then
                    env_product_q <=
                        pcm_i * signed('0' & std_logic_vector(gain_i));

                    if velocity_i = to_unsigned(127, 7) then
                        velocity_q <= to_signed(128, 9);
                    else
                        velocity_q <=
                            to_signed(to_integer(velocity_i), 9);
                    end if;
                end if;

                -- Stage B: Multiply by MIDI velocity.
                valid_2_q <= valid_1_q;

                if valid_1_q = '1' then
                    final_product_q <=
                        env_product_q * velocity_q;
                end if;

                -- Stage C: Fixed-point scaling and saturation.
                valid_q <= valid_2_q;

                if valid_2_q = '1' then
                    scaled := shift_right(final_product_q, 23);

                    if scaled > to_signed(127, 34) then
                        pcm_q <= to_signed(127, 8);
                    elsif scaled < to_signed(-128, 34) then
                        pcm_q <= to_signed(-128, 8);
                    else
                        pcm_q <= resize(scaled, 8);
                    end if;
                end if;
            end if;
        end if;
    end process;

    pcm_o       <= pcm_q;
    out_valid_o <= valid_q;

end architecture;
