library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Streaming high-pass filter before recording. Signed PCM8 input/output,
-- Q8 internal state. Approximate pole alpha=1-2**(-LEAK_SHIFT).
-- At 16 kHz, LEAK_SHIFT=8 gives a cutoff of approximately 10 Hz.
-- y[n] = x[n]-x[n-1]+y[n-1]-leak(y[n-1]). The leakage magnitude
-- rounds UP, so either signed residue converges exactly to zero.
-- Input accepted at N -> output after N+2. Minimum input spacing: 3 clocks.
-- Internal state is not clipped to PCM8; only the public output saturates.
entity dc_blocker is
    generic (LEAK_SHIFT : positive := 8);
    port (
        clk, rst, in_valid : in std_logic;
        pcm_i : in signed(7 downto 0);
        pcm_o : out signed(7 downto 0);
        out_valid, clipped : out std_logic
    );
end entity;
architecture rtl of dc_blocker is
    subtype state_t is signed(19 downto 0);
    constant LEAK_ROUND : state_t := to_signed(2**LEAK_SHIFT-1, 20);
    signal previous_x : signed(7 downto 0) := (others => '0');
    signal state_q, delta_q, leakage_q : state_t := (others => '0');
    signal valid0, valid1, valid_q, clipped_q : std_logic := '0';
    signal pcm_q : signed(7 downto 0) := (others => '0');
begin
    assert LEAK_SHIFT <= 16 report "dc_blocker LEAK_SHIFT must be 1..16" severity failure;
    pcm_o <= pcm_q;
    out_valid <= valid_q;
    clipped <= clipped_q;
    process(clk)
        variable rounded : state_t;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                previous_x <= (others => '0');
                state_q <= (others => '0'); delta_q <= (others => '0');
                leakage_q <= (others => '0'); pcm_q <= (others => '0');
                valid0 <= '0'; valid1 <= '0'; valid_q <= '0'; clipped_q <= '0';
            else
                valid0 <= in_valid; valid1 <= valid0; valid_q <= valid1;
                clipped_q <= '0';
                -- synthesis translate_off
                assert not (in_valid = '1' and (valid0 = '1' or valid1 = '1'))
                    report "dc_blocker needs at least three clocks between samples"
                    severity failure;
                -- synthesis translate_on
                if in_valid = '1' then
                    delta_q <= shift_left(resize(pcm_i, 20)-resize(previous_x, 20), 8);
                    previous_x <= pcm_i;
                    if state_q > 0 then
                        leakage_q <= shift_right(state_q+LEAK_ROUND, LEAK_SHIFT);
                    elsif state_q < 0 then
                        leakage_q <= -shift_right(-state_q+LEAK_ROUND, LEAK_SHIFT);
                    else leakage_q <= (others => '0'); end if;
                end if;
                if valid0 = '1' then state_q <= state_q+delta_q-leakage_q; end if;
                if valid1 = '1' then
                    if state_q < 0 then rounded := -shift_right(-state_q+128, 8);
                    else rounded := shift_right(state_q+128, 8); end if;
                    if rounded > 127 then pcm_q <= to_signed(127, 8); clipped_q <= '1';
                    elsif rounded < -128 then pcm_q <= to_signed(-128, 8); clipped_q <= '1';
                    else pcm_q <= resize(rounded, 8); end if;
                end if;
            end if;
        end if;
    end process;
end architecture;
