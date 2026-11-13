-- Scalar mathematical reference versus the streaming three-register pipeline.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
entity tb_audio_gain is end entity;
architecture sim of tb_audio_gain is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal pcm_i, pcm_o : signed(7 downto 0) := (others => '0');
    signal gain_i : unsigned(15 downto 0) := (others => '0');
    signal velocity_i : unsigned(6 downto 0) := (others => '0');
    signal valid_i, valid_o : std_logic := '0';
begin
    clk <= not clk after 5 ns;
    dut : entity work.audio_gain port map (
        clk => clk, rst => rst, pcm_i => pcm_i, gain_i => gain_i,
        velocity_i => velocity_i, in_valid_i => valid_i,
        pcm_o => pcm_o, out_valid_o => valid_o
    );
    watchdog : process begin
        wait for 1 ms;
        assert false report "tb_audio_gain timeout" severity failure;
    end process;
    stimulus : process
        type ints_t is array(natural range <>) of integer;
        constant gains : ints_t := (0, 1, 32768, 65534, 65535);
        constant velocities : ints_t := (0, 1, 64, 126, 127);
        variable expected : ints_t(0 to 2) := (others => 0);
        variable valid : std_logic_vector(0 to 2) := (others => '0');
        variable checked : natural := 0;
        procedure cycle(p, g, v : integer; present : std_logic := '1'; reset : std_logic := '0') is
            variable coeff, product, reference : integer;
        begin
            wait until falling_edge(clk);
            pcm_i <= to_signed(p, 8); gain_i <= to_unsigned(g, 16);
            velocity_i <= to_unsigned(v, 7); valid_i <= present; rst <= reset;
            if reset = '1' then
                valid := (others => '0'); expected := (others => 0);
            else
                valid(2) := valid(1); valid(1) := valid(0); valid(0) := present;
                expected(2) := expected(1); expected(1) := expected(0);
                coeff := v;
                if v = 127 then coeff := 128; end if;
                product := p * g * coeff;
                if product >= 0 then reference := product / 8388608;
                else reference := -((-product + 8388607) / 8388608); end if;
                expected(0) := reference;
            end if;
            wait until rising_edge(clk); wait for 1 ns;
            assert valid_o = valid(2) report "Gain valid alignment mismatch" severity failure;
            if valid(2) = '1' then
                assert to_integer(pcm_o) = expected(2)
                    report "Gain arithmetic mismatch: got " & integer'image(to_integer(pcm_o)) &
                           " expected " & integer'image(expected(2)) severity failure;
                checked := checked + 1;
            elsif reset = '1' then
                assert pcm_o = 0 report "Gain reset mismatch" severity failure;
            end if;
        end procedure;
    begin
        cycle(0, 0, 0, '0', '1');
        for p in -128 to 127 loop
            for gi in gains'range loop
                for vi in velocities'range loop
                    cycle(p, gains(gi), velocities(vi));
                end loop;
            end loop;
            cycle(42, 111, 90, '0'); -- inputs may change without a transaction
        end loop;
        for i in 1 to 3 loop cycle(0, 0, 0, '0'); end loop;
        assert checked = 6400 report "Gain regression lost samples" severity failure;
        cycle(120, 65535, 127);
        cycle(-120, 65535, 127);
        cycle(0, 0, 0, '0', '1'); -- flush in-flight samples
        for i in 1 to 3 loop cycle(0, 0, 0, '0'); end loop;
        report "PASS: tb_audio_gain" severity note;
        stop; wait;
    end process;
end architecture;
