library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Stage 09 feedback echo. Input/output PCM remain signed 16 bit.
-- Accept when in_valid AND in_ready are high at edge N; output after N+1.
-- Maximum throughput: one transaction every two system-clock cycles.
-- Delay length counts accepted audio samples, including zero-valued samples.
-- y[n] = sat16(x[n] + floor(y[n-delay]/2)); bypass changes output only.
-- Buffer feedback continues during bypass. Reset invalidates RAM contents;
-- it does not clear the RAM array. A negative -1 internal residue is retained
-- by arithmetic-shift feedback, as in Stage 09.
-- RAM access is isolated in a reset-free clocked process for block-RAM
-- inference. Control reset gates its port enables and invalidates metadata.
entity delay_effect is
    generic (G_DELAY_SAMPLES : positive := 4096);
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;
        in_valid      : in  std_logic;
        in_ready      : out std_logic;
        in_sample     : in  signed(15 downto 0);
        effect_enable : in  std_logic;
        out_valid     : out std_logic;
        out_sample    : out signed(15 downto 0)
    );
end entity;

architecture rtl of delay_effect is
    type ram_t is array (0 to G_DELAY_SAMPLES-1) of signed(15 downto 0);
    signal delay_ram : ram_t;
    attribute ram_style : string;
    attribute ram_style of delay_ram : signal is "block";
    type state_t is (IDLE, PROCESS_SAMPLE);
    signal state : state_t := IDLE;
    signal pointer : natural range 0 to G_DELAY_SAMPLES-1 := 0;
    signal filled_count : natural range 0 to G_DELAY_SAMPLES := 0;
    signal ram_read : signed(15 downto 0);
    signal dry_reg, output_reg : signed(15 downto 0) := (others => '0');
    signal enable_reg, delayed_valid, output_valid_r : std_logic := '0';
    signal ram_read_enable, ram_write_enable : std_logic;
    signal mixed_sample : signed(15 downto 0) := (others => '0');

    function saturate_16(value : signed(16 downto 0)) return signed is
    begin
        if value > to_signed(32767, 17) then
            return to_signed(32767, 16);
        elsif value < to_signed(-32768, 17) then
            return to_signed(-32768, 16);
        else
            return resize(value, 16);
        end if;
    end function;
begin
    in_ready <= '1' when state = IDLE and rst = '0' else '0';
    out_valid <= output_valid_r;
    out_sample <= output_reg;

    ram_read_enable <= '1' when state = IDLE and in_valid = '1'
                       and rst = '0' else '0';
    ram_write_enable <= '1' when state = PROCESS_SAMPLE and rst = '0' else '0';

    -- One synchronous read port and one synchronous write port. Neither
    -- the array nor its read register has a reset or a whole-array mux.
    memory_ports : process(clk)
    begin
        if rising_edge(clk) then
            if ram_write_enable = '1' then
                delay_ram(pointer) <= mixed_sample;
            end if;
            if ram_read_enable = '1' then
                ram_read <= delay_ram(pointer);
            end if;
        end if;
    end process;

    -- The same saturated value feeds RAM feedback and the wet output.
    -- Ignore unfilled/stale RAM positions until one complete refill.
    feedback_sum : process(all)
        variable delayed : signed(15 downto 0);
        variable feedback : signed(16 downto 0);
    begin
        delayed := (others => '0');
        if delayed_valid = '1' then delayed := ram_read; end if;
        feedback := shift_right(resize(delayed, 17), 1);
        mixed_sample <= saturate_16(resize(dry_reg, 17) + feedback);
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            output_valid_r <= '0';
            if rst = '1' then
                state <= IDLE;
                pointer <= 0;
                filled_count <= 0;
                dry_reg <= (others => '0');
                enable_reg <= '0';
                delayed_valid <= '0';
                output_reg <= (others => '0');
            else
                case state is
                    when IDLE =>
                        if in_valid = '1' then
                            dry_reg <= in_sample;
                            enable_reg <= effect_enable;
                            delayed_valid <= '0';
                            if filled_count = G_DELAY_SAMPLES then
                                delayed_valid <= '1';
                            end if;
                            state <= PROCESS_SAMPLE;
                        end if;
                    when PROCESS_SAMPLE =>
                        if enable_reg = '1' then
                            output_reg <= mixed_sample;
                        else
                            output_reg <= dry_reg;
                        end if;
                        output_valid_r <= '1';
                        if pointer = G_DELAY_SAMPLES-1 then
                            pointer <= 0;
                        else
                            pointer <= pointer+1;
                        end if;
                        if filled_count < G_DELAY_SAMPLES then
                            filled_count <= filled_count+1;
                        end if;
                        state <= IDLE;
                end case;
            end if;
        end if;
    end process;
end architecture;
