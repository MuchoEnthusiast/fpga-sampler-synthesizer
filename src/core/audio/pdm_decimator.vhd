library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Three-integrator/three-comb CIC, migrated from Stage 12 and scheduled
-- across fabric-clock cycles. Bipolar PDM: '1' -> +1, '0' -> -1.
-- Every G_DECIMATION accepted bits creates a PCM candidate; discard the
-- first two candidates after reset while the CIC impulse response fills.
-- Last PDM bit accepted at edge N -> PCM output after edge N+6.
-- Input strobes must be at least three clocks apart (normally 50 clocks).
-- Modulo 2^32 integrator/comb arithmetic is intentional. Output rounding
-- preserves Stage 12: nearest, with ties toward +infinity, then saturation.
-- Default 2 MHz / 125 = 16 kHz; DC full scale is +/-119 PCM with SHIFT=14.
-- SHIFT=12 provides 4x microphone gain. clipped marks saturated samples.
entity pdm_decimator is
    generic (
        G_DECIMATION : positive := 125;
        G_SHIFT : positive := 14
    );
    port (
        clk, rst : in std_logic;
        pdm_bit, pdm_valid : in std_logic;
        pcm_sample : out signed(7 downto 0);
        pcm_valid : out std_logic;
        ready, clipped : out std_logic
    );
end entity;

architecture rtl of pdm_decimator is
    constant WIDTH : positive := 32;
    subtype word_t is signed(WIDTH-1 downto 0);
    constant ROUND_HALF : signed(WIDTH downto 0) :=
        shift_left(to_signed(1, WIDTH+1), G_SHIFT-1);
    signal int1, int2, int3 : word_t := (others => '0');
    signal delay1, delay2, delay3 : word_t := (others => '0');
    signal comb_input, comb1, comb2, comb3 : word_t := (others => '0');
    signal i1_valid, i2_valid, last1, last2 : std_logic := '0';
    signal c0_valid, c1_valid, c2_valid, c3_valid : std_logic := '0';
    signal bit_count : natural range 0 to G_DECIMATION-1 := 0;
    signal warm_count : natural range 0 to 2 := 0;
    signal sample_q : signed(7 downto 0) := (others => '0');
    signal valid_q, ready_q, clipped_q : std_logic := '0';
begin
    assert G_DECIMATION <= 1000
        report "pdm_decimator: decimation exceeds the 32-bit CIC bound"
        severity failure;
    assert G_SHIFT < WIDTH-1
        report "pdm_decimator: unsupported output shift" severity failure;
    pcm_sample <= sample_q;
    pcm_valid <= valid_q;
    ready <= ready_q;
    clipped <= clipped_q;

    process(clk)
        variable next_int3 : word_t;
        variable rounded : signed(WIDTH downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                int1 <= (others => '0'); int2 <= (others => '0');
                int3 <= (others => '0');
                delay1 <= (others => '0'); delay2 <= (others => '0');
                delay3 <= (others => '0');
                comb_input <= (others => '0'); comb1 <= (others => '0');
                comb2 <= (others => '0'); comb3 <= (others => '0');
                i1_valid <= '0'; i2_valid <= '0'; last1 <= '0'; last2 <= '0';
                c0_valid <= '0'; c1_valid <= '0'; c2_valid <= '0'; c3_valid <= '0';
                bit_count <= 0; warm_count <= 0;
                sample_q <= (others => '0');
                valid_q <= '0'; ready_q <= '0'; clipped_q <= '0';
            else
                valid_q <= '0'; clipped_q <= '0';
                i1_valid <= pdm_valid; i2_valid <= i1_valid;
                last1 <= '0'; last2 <= last1;
                c0_valid <= '0'; c1_valid <= c0_valid;
                c2_valid <= c1_valid; c3_valid <= c2_valid;

                -- synthesis translate_off
                assert not (pdm_valid = '1' and (i1_valid = '1' or i2_valid = '1'))
                    report "pdm_decimator needs at least three clocks between input bits"
                    severity failure;
                -- synthesis translate_on

                if pdm_valid = '1' then
                    if pdm_bit = '1' then int1 <= int1 + 1;
                    else int1 <= int1 - 1; end if;
                    if bit_count = G_DECIMATION-1 then
                        bit_count <= 0; last1 <= '1';
                    else bit_count <= bit_count+1; end if;
                end if;
                if i1_valid = '1' then int2 <= int2 + int1; end if;
                if i2_valid = '1' then
                    next_int3 := int3 + int2;
                    int3 <= next_int3;
                    if last2 = '1' then
                        comb_input <= next_int3; c0_valid <= '1';
                    end if;
                end if;
                if c0_valid = '1' then
                    comb1 <= comb_input-delay1; delay1 <= comb_input;
                end if;
                if c1_valid = '1' then
                    comb2 <= comb1-delay2; delay2 <= comb1;
                end if;
                if c2_valid = '1' then
                    comb3 <= comb2-delay3; delay3 <= comb2;
                end if;
                if c3_valid = '1' then
                    if warm_count < 2 then
                        warm_count <= warm_count+1;
                    else
                        rounded := shift_right(resize(comb3, WIDTH+1) + ROUND_HALF, G_SHIFT);
                        if rounded > 127 then
                            sample_q <= to_signed(127, 8); clipped_q <= '1';
                        elsif rounded < -128 then
                            sample_q <= to_signed(-128, 8); clipped_q <= '1';
                        else sample_q <= resize(rounded, 8); end if;
                        valid_q <= '1'; ready_q <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
