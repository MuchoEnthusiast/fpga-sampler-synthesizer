-- Fractional sample position. Migrated from Stage 03.
-- Synthesizable, board-independent VHDL (numeric_std).
--
-- Q(ADDR_BITS).(FRAC_BITS) position, measured in source sample indices.
-- On each advance_i pulse: phase <- (phase + step_i) mod sample_length_i.
-- step_i is UQ2.FRAC_BITS: 0 <= step < 4 source samples per tick.
-- The current index/fraction are available BEFORE the advance edge.
-- Runtime lengths 4..RAM depth need at most one wrap subtraction. Invalid
-- lengths mute/reset phase. SAMPLE_COUNT supplies the default legacy length.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity phase_accumulator is
    generic (
        ADDR_BITS    : positive := 14;
        FRAC_BITS    : positive := 16;
        SAMPLE_COUNT : positive := 16_000
    );
    port (
        clk_i       : in  std_logic;
        rst_i       : in  std_logic; -- synchronous active-high reset
        advance_i   : in  std_logic; -- one-clock enable, usually at 16 kHz
        step_i      : in  unsigned(FRAC_BITS + 1 downto 0);
        index_o     : out unsigned(ADDR_BITS - 1 downto 0) := (others => '0');
        fraction_o  : out unsigned(FRAC_BITS - 1 downto 0) := (others => '0');
        sample_length_i : in unsigned(ADDR_BITS downto 0) :=
            to_unsigned(SAMPLE_COUNT, ADDR_BITS+1)
    );
end entity;

architecture rtl of phase_accumulator is
    constant PHASE_BITS : positive := ADDR_BITS + FRAC_BITS;
    signal phase_q : unsigned(PHASE_BITS - 1 downto 0) := (others => '0');
begin
    assert SAMPLE_COUNT >= 4 and SAMPLE_COUNT <= 2**ADDR_BITS
        report "phase_accumulator: SAMPLE_COUNT outside supported RAM range (4 .. 2**ADDR_BITS)"
        severity failure;

    -- Continuous read address: stable between audio sample ticks.
    index_o    <= phase_q(PHASE_BITS - 1 downto FRAC_BITS);
    fraction_o <= phase_q(FRAC_BITS - 1 downto 0);

    process(clk_i)
        variable phase_sum : unsigned(PHASE_BITS downto 0);
        variable integer_sum : unsigned(ADDR_BITS downto 0);
    begin
        if rising_edge(clk_i) then
            if rst_i = '1' or sample_length_i < 4 or
               sample_length_i > to_unsigned(2**ADDR_BITS, ADDR_BITS+1) then
                phase_q <= (others => '0');
            elsif resize(phase_q(PHASE_BITS-1 downto FRAC_BITS), ADDR_BITS+1)
                  >= sample_length_i then
                -- A shorter runtime clip cannot retain an out-of-range phase.
                phase_q <= (others => '0');
            elsif advance_i = '1' then
                phase_sum := ('0' & phase_q) + resize(step_i, PHASE_BITS + 1);
                integer_sum := phase_sum(PHASE_BITS downto FRAC_BITS);
                -- The loop boundary has no fractional bits. Comparing and
                -- subtracting only its integer field shortens the wrap logic.
                if integer_sum >= sample_length_i then
                    integer_sum := integer_sum - sample_length_i;
                end if;
                phase_q <= integer_sum(ADDR_BITS-1 downto 0) &
                           phase_sum(FRAC_BITS-1 downto 0);
            end if;
        end if;
    end process;
end architecture;
