-- Migrated Stage 11 capture. The only clock domain is clk.
-- M_CLK is an output signal, never a fabric clock.
-- Default: 100 MHz / (2*25) = 2 MHz; startup wait = 50 ms.
-- Capture the valid microphone bit at the rising M_CLK boundary,
-- then publish it after two system-clock cycles with a one-cycle strobe.
library ieee;
use ieee.std_logic_1164.all;

entity pdm_capture is
    generic (
        G_HALF_PERIOD_CYCLES : positive := 25;
        G_WARMUP_CYCLES      : natural  := 5_000_000
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        mic_data  : in  std_logic;
        mic_clk   : out std_logic;
        mic_lrsel : out std_logic;
        ready     : out std_logic;
        pdm_bit   : out std_logic;
        pdm_valid : out std_logic
    );
end entity;

architecture rtl of pdm_capture is
    signal half_count : natural range 0 to G_HALF_PERIOD_CYCLES-1 := 0;
    signal warm_count : natural range 0 to G_WARMUP_CYCLES := 0;
    signal mic_clk_r  : std_logic := '0';
    signal pdm_meta   : std_logic := '0';
    signal pdm_sync   : std_logic := '0';
    signal sample_d1  : std_logic := '0';
    signal sample_d2  : std_logic := '0';

    attribute ASYNC_REG : string;
    attribute ASYNC_REG of pdm_meta, pdm_sync : signal is "TRUE";
    attribute SHREG_EXTRACT : string;
    attribute SHREG_EXTRACT of pdm_meta, pdm_sync : signal is "NO";
begin
    assert G_HALF_PERIOD_CYCLES >= 4
        report "The capture pipeline needs at least four clocks per half-period"
        severity failure;

    mic_clk   <= mic_clk_r;
    mic_lrsel <= '0';
    ready <= '1' when warm_count = G_WARMUP_CYCLES and rst = '0' else '0';

    -- Both receiving registers run continuously at the system clock.
    process(clk)
    begin
        if rising_edge(clk) then
            pdm_meta <= mic_data;
            pdm_sync <= pdm_meta;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                half_count <= 0;
                warm_count <= 0;
                mic_clk_r  <= '0';
                sample_d1  <= '0';
                sample_d2  <= '0';
                pdm_bit    <= '0';
                pdm_valid  <= '0';
            else
                sample_d1 <= '0';
                sample_d2 <= sample_d1;
                pdm_valid <= sample_d2;
                if sample_d2 = '1' then
                    pdm_bit <= pdm_sync;
                end if;

                if warm_count < G_WARMUP_CYCLES then
                    warm_count <= warm_count + 1;
                end if;

                if half_count = G_HALF_PERIOD_CYCLES-1 then
                    half_count <= 0;
                    mic_clk_r <= not mic_clk_r;
                    if mic_clk_r = '0' and warm_count = G_WARMUP_CYCLES then
                        -- E0: capture pin in pdm_meta and launch M_CLK rising.
                        -- E1: pdm_sync receives that bit.
                        -- E2: publish the bit with a one-cycle valid pulse.
                        sample_d1 <= '1';
                    end if;
                else
                    half_count <= half_count + 1;
                end if;
            end if;
        end if;
    end process;
end architecture;