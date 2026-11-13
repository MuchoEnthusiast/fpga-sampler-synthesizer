-- Signed 8-bit PCM interpolation. Migrated from Stage 04.
-- Portable synthesizable VHDL-2008; no new clock domain.
-- Valid input on edge N -> valid output after edge N+2 (3 register stages).
-- y = s0 + round_away_from_zero((s1-s0)*fraction/2**FRAC_BITS).
-- The signed delta is rounded before adding s0; output is saturated.
-- If fraction=0, output is exactly s0.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity linear_interpolator is
    generic (
        FRAC_BITS : positive := 16
    );
    port (
        clk_i       : in  std_logic;
        rst_i       : in  std_logic; -- synchronous active-high
        in_valid_i  : in  std_logic;
        sample_a_i  : in  signed(7 downto 0);
        sample_b_i  : in  signed(7 downto 0);
        fraction_i  : in  unsigned(FRAC_BITS - 1 downto 0);
        pcm_o       : out signed(7 downto 0);
        out_valid_o : out std_logic
    );
end entity;

architecture rtl of linear_interpolator is
    -- 9-bit signed delta (-255 .. +255) * (FRAC_BITS+1)-bit
    -- nonnegative signed fraction: full product FRAC_BITS+10 bits.
    constant PRODUCT_BITS : positive := FRAC_BITS + 10;
    constant ROUND_HALF : signed(PRODUCT_BITS - 1 downto 0) :=
        to_signed(2**(FRAC_BITS - 1), PRODUCT_BITS);
    constant MAX_PCM : signed(PRODUCT_BITS - 1 downto 0) :=
        to_signed(127, PRODUCT_BITS);
    constant MIN_PCM : signed(PRODUCT_BITS - 1 downto 0) :=
        to_signed(-128, PRODUCT_BITS);

    signal a_s0      : signed(7 downto 0) := (others => '0');
    signal delta_s0  : signed(8 downto 0) := (others => '0');
    signal frac_s0   : signed(FRAC_BITS downto 0) := (others => '0');
    signal valid_s0  : std_logic := '0';

    signal a_s1      : signed(7 downto 0) := (others => '0');
    signal product_s1 : signed(PRODUCT_BITS - 1 downto 0) := (others => '0');
    signal valid_s1  : std_logic := '0';

    signal pcm_q     : signed(7 downto 0) := (others => '0');
    signal valid_q   : std_logic := '0';
begin
    assert FRAC_BITS <= 24
        report "linear_interpolator: FRAC_BITS > 24 is not supported by the ROUND_HALF integer constant"
        severity failure;

    process(clk_i)
        variable magnitude_v : signed(PRODUCT_BITS - 1 downto 0);
        variable delta_v     : signed(PRODUCT_BITS - 1 downto 0);
        variable result_v    : signed(PRODUCT_BITS - 1 downto 0);
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' then
                a_s0       <= (others => '0');
                delta_s0   <= (others => '0');
                frac_s0    <= (others => '0');
                valid_s0   <= '0';
                a_s1       <= (others => '0');
                product_s1 <= (others => '0');
                valid_s1   <= '0';
                pcm_q      <= (others => '0');
                valid_q    <= '0';
            else
                valid_s0 <= in_valid_i;
                valid_s1 <= valid_s0;
                valid_q  <= valid_s1;

                -- Stage 0: capture operands and signed sample difference.
                if in_valid_i = '1' then
                    a_s0     <= sample_a_i;
                    delta_s0 <= resize(sample_b_i, 9) - resize(sample_a_i, 9);
                    frac_s0  <= signed('0' & std_logic_vector(fraction_i));
                end if;

                -- Stage 1: signed multiply, eligible for DSP inference.
                if valid_s0 = '1' then
                    product_s1 <= delta_s0 * frac_s0;
                    a_s1      <= a_s0;
                end if;

                -- Stage 2: symmetric nearest rounding, signed add, saturation.
                if valid_s1 = '1' then
                    if product_s1(PRODUCT_BITS - 1) = '0' then
                        delta_v := shift_right(product_s1 + ROUND_HALF, FRAC_BITS);
                    else
                        magnitude_v := -product_s1;
                        delta_v := -shift_right(magnitude_v + ROUND_HALF, FRAC_BITS);
                    end if;

                    result_v := resize(a_s1, PRODUCT_BITS) + delta_v;
                    if result_v > MAX_PCM then
                        pcm_q <= to_signed(127, 8);
                    elsif result_v < MIN_PCM then
                        pcm_q <= to_signed(-128, 8);
                    else
                        pcm_q <= resize(result_v, 8);
                    end if;
                end if;
            end if;
        end if;
    end process;

    pcm_o       <= pcm_q;
    out_valid_o <= valid_q;
end architecture;
