-- One-read-port BRAM interpolation player. Migrated from Stage 04.
-- Reuses phase_accumulator and linear_interpolator.
-- Single 100 MHz clock; sample_tick_i is a one-cycle enable (16 kHz).
-- The RAM must have a synchronous registered read output (sample_ram).
-- Prefetch: address A -> capture A / address B -> capture B ->
-- 3-stage interpolation pipeline -> READY. Allow >= 8 cycles between
-- sample ticks (real board: 6250 cycles). No dynamic RAM writes during
-- this protocol. The current phase advances only on accepted ticks.
-- A tick before READY is ignored; ready_o permits explicit testing.
-- Runtime clip lengths 4..RAM depth are supported. Changing length restarts
-- prefetch and phase; keep length stable while playing a committed clip.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sample_player is
    generic (
        ADDR_BITS    : positive := 14;
        FRAC_BITS    : positive := 16;
        SAMPLE_COUNT : positive := 16_000
    );
    port (
        clk_i           : in  std_logic;
        rst_i           : in  std_logic;
        play_i          : in  std_logic;
        sample_tick_i   : in  std_logic;
        step_i          : in  unsigned(FRAC_BITS + 1 downto 0);
        linear_mode_i   : in  std_logic; -- '0': nearest; '1': linear
        rd_addr_o       : out unsigned(ADDR_BITS - 1 downto 0);
        rd_data_i       : in  signed(7 downto 0);
        phase_frac_o    : out unsigned(FRAC_BITS - 1 downto 0);
        pcm_o           : out signed(7 downto 0);
        pcm_valid_o     : out std_logic;
        ready_o         : out std_logic;
        sample_length_i : in unsigned(ADDR_BITS downto 0) :=
            to_unsigned(SAMPLE_COUNT, ADDR_BITS+1)
    );
end entity;

architecture rtl of sample_player is
    type prefetch_state_t is (
        ISSUE_A, CAPTURE_A_ISSUE_B, CAPTURE_B, LAUNCH, WAIT_RESULT, READY
    );
    signal state_q    : prefetch_state_t := ISSUE_A;
    signal phase_idx  : unsigned(ADDR_BITS - 1 downto 0) := (others => '0');
    signal phase_frac : unsigned(FRAC_BITS - 1 downto 0) := (others => '0');
    signal neighbor_idx : unsigned(ADDR_BITS - 1 downto 0);
    signal advance    : std_logic;
    signal length_q : unsigned(ADDR_BITS downto 0) :=
        to_unsigned(SAMPLE_COUNT, ADDR_BITS+1);
    signal length_valid, player_reset : std_logic;

    signal sample_a_q : signed(7 downto 0) := (others => '0');
    signal sample_b_q : signed(7 downto 0) := (others => '0');
    signal interp_pcm : signed(7 downto 0);
    signal interp_valid : std_logic;
    signal interp_launch : std_logic;
    signal pcm_q      : signed(7 downto 0) := (others => '0');
    signal pcm_valid_q : std_logic := '0';
begin
    assert SAMPLE_COUNT >= 4 and SAMPLE_COUNT <= 2**ADDR_BITS
        report "sample_player: SAMPLE_COUNT must fit the selected RAM address width"
        severity failure;

    length_valid <= '1' when sample_length_i >= 4 and
        sample_length_i <= to_unsigned(2**ADDR_BITS, ADDR_BITS+1) else '0';
    player_reset <= '1' when rst_i = '1' or length_valid = '0' or
                            length_q /= sample_length_i else '0';

    -- Wrap at the actual recorded length, never into old/padded RAM data.
    neighbor_idx <= (others => '0') when
        resize(phase_idx, ADDR_BITS+1) + 1 >= sample_length_i
        else phase_idx + 1;

    -- ISSUE_A supplies the current phase address to BRAM. On the next
    -- edge CAPTURE_A_ISSUE_B reads its registered value and requests B.
    rd_addr_o <= (others => '0') when player_reset = '1' else
                 phase_idx when state_q = ISSUE_A or state_q = READY
                 else neighbor_idx;

    advance <= '1' when player_reset = '0' and play_i = '1' and
                        sample_tick_i = '1' and state_q = READY else '0';
    interp_launch <= '1' when state_q = LAUNCH and player_reset = '0' else '0';

    u_phase : entity work.phase_accumulator
        generic map (
            ADDR_BITS => ADDR_BITS,
            FRAC_BITS => FRAC_BITS,
            SAMPLE_COUNT => SAMPLE_COUNT
        )
        port map (
            clk_i      => clk_i,
            rst_i      => player_reset,
            advance_i  => advance,
            step_i     => step_i,
            index_o    => phase_idx,
            fraction_o => phase_frac,
            sample_length_i => sample_length_i
        );

    u_interp : entity work.linear_interpolator
        generic map (FRAC_BITS => FRAC_BITS)
        port map (
            clk_i       => clk_i,
            rst_i       => player_reset,
            in_valid_i  => interp_launch,
            sample_a_i  => sample_a_q,
            sample_b_i  => sample_b_q,
            fraction_i  => phase_frac,
            pcm_o       => interp_pcm,
            out_valid_o => interp_valid
        );

    process(clk_i)
    begin
        if rising_edge(clk_i) then
            length_q <= sample_length_i;
            if player_reset = '1' then
                state_q     <= ISSUE_A;
                sample_a_q  <= (others => '0');
                sample_b_q  <= (others => '0');
                pcm_q       <= (others => '0');
                pcm_valid_q <= '0';
            else
                pcm_valid_q <= '0';
                if play_i = '0' then
                    pcm_q <= (others => '0'); -- muted, retain phase/prefetch
                end if;

                case state_q is
                    when ISSUE_A =>
                        -- BRAM samples phase_idx on this rising edge.
                        state_q <= CAPTURE_A_ISSUE_B;

                    when CAPTURE_A_ISSUE_B =>
                        -- BRAM registered data from ISSUE_A is now visible.
                        sample_a_q <= rd_data_i;
                        state_q <= CAPTURE_B;

                    when CAPTURE_B =>
                        -- BRAM registered data from prior request B.
                        sample_b_q <= rd_data_i;
                        state_q <= LAUNCH;

                    when LAUNCH =>
                        -- Interpolator captures operands on this edge.
                        state_q <= WAIT_RESULT;

                    when WAIT_RESULT =>
                        if interp_valid = '1' then
                            state_q <= READY;
                        end if;

                    when READY =>
                        if advance = '1' then
                            if linear_mode_i = '1' then
                                pcm_q <= interp_pcm;
                            else
                                pcm_q <= sample_a_q;
                            end if;
                            pcm_valid_q <= '1';
                            state_q <= ISSUE_A; -- next phase is updated now
                        end if;
                end case;
            end if;
        end if;
    end process;

    phase_frac_o <= phase_frac;
    pcm_o        <= pcm_q;
    pcm_valid_o  <= pcm_valid_q;
    ready_o      <= '1' when state_q = READY and player_reset = '0' else '0';
end architecture;
