library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.audio_pkg.all;

entity tb_sampler_core is end entity;
architecture sim of tb_sampler_core is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal tick, note_on, note_off, dist, drive4, echo : std_logic := '0';
    signal note_number : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(69, 7));
    signal velocity : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(127, 7));
    signal pcm : pcm8_t;
    signal valid, held, active, ready, error_flag : std_logic;
    signal current_note : std_logic_vector(6 downto 0);
    type integers_t is array(natural range <>) of integer;
    constant SAMPLE : integers_t(0 to 7) := (64, 32, -64, -32, 0, 127, -128, 16);
    function floor_div(a : integer; b : positive) return integer is
    begin
        if a < 0 then return -((-a + b - 1) / b); end if;
        return a / b;
    end function;
    function clip(a, lo, hi : integer) return integer is
    begin
        if a < lo then return lo; elsif a > hi then return hi; end if;
        return a;
    end function;
begin
    clk <= not clk after 5 ns;
    dut : entity work.sampler_core
        generic map (ADDR_BITS => 3, SAMPLE_COUNT => 8, INIT_FILE => "test_core.mem", PRELOADED_SAMPLES => 8,
                     ECHO_DELAY_SAMPLES => 4, ATTACK_RATE_G => x"00000000",
                     DECAY_RATE_G => x"00000000", SUSTAIN_G => x"8000", RELEASE_RATE_G => x"00000000")
        port map (clk, rst, tick, note_on, note_off, note_number, velocity,
                  '1', dist, drive4, echo, pcm, valid, current_note, held, active, ready, error_flag);
    process
        variable buffer_model : integers_t(0 to 3) := (others => 0);
        variable pointer : natural range 0 to 3 := 0;
        variable saw_tail : boolean := false;
        procedure clocks(n : positive) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); wait for 1 ns; end loop;
        end procedure;
        procedure event(on_event : boolean; n : natural; v : natural := 127) is
        begin
            wait until falling_edge(clk);
            note_number <= std_logic_vector(to_unsigned(n, 7));
            velocity <= std_logic_vector(to_unsigned(v, 7));
            if on_event then note_on <= '1'; else note_off <= '1'; end if;
            wait until falling_edge(clk); note_on <= '0'; note_off <= '0';
            clocks(12);
        end procedure;
        procedure check_tick(raw : integer; vel : natural := 127; expect_tail : boolean := false) is
            variable dry, coeff, mixed, expected : integer;
        begin
            coeff := vel; if vel = 127 then coeff := 128; end if;
            dry := floor_div(raw * coeff, 256); -- envelope = 32768/65536
            if dist = '1' then
                if drive4 = '1' then dry := clip(dry * 4, -128, 127);
                else dry := clip(dry * 2, -128, 127); end if;
            end if;
            mixed := clip(dry * 256 + floor_div(buffer_model(pointer), 2), -32768, 32767);
            buffer_model(pointer) := mixed;
            pointer := (pointer + 1) mod 4;
            expected := dry;
            if echo = '1' then
                if mixed < 0 then expected := -((-mixed + 128) / 256);
                else expected := (mixed + 128) / 256; end if;
                expected := clip(expected, -128, 127);
            end if;
            wait until falling_edge(clk); tick <= '1';
            wait until rising_edge(clk); wait for 1 ns; tick <= '0';
            assert valid = '0' report "Output arrived on input edge" severity failure;
            for age in 1 to 15 loop
                clocks(1);
                if age = 9 then
                    assert valid = '1' report "Missing output at N+9" severity failure;
                    assert to_integer(pcm) = expected
                        report "Core expected " & integer'image(expected) & " got " & integer'image(to_integer(pcm))
                        severity failure;
                    if expect_tail and pcm /= 0 then saw_tail := true; end if;
                else
                    assert valid = '0' report "Unexpected/duplicate output transaction" severity failure;
                end if;
                assert error_flag = '0' report "Core raised stream_error" severity failure;
            end loop;
        end procedure;
    begin
        clocks(3); wait until falling_edge(clk); rst <= '0'; clocks(12);
        for i in 1 to 4 loop check_tick(0); end loop;
        event(true, 69);
        for i in 0 to 15 loop check_tick(SAMPLE(i mod 8)); end loop;
        dist <= '1'; echo <= '1'; clocks(1);
        for i in 0 to 9 loop check_tick(SAMPLE(i mod 8)); end loop;
        event(false, 70); assert held = '1' report "Wrong-note off stopped voice" severity failure;
        check_tick(SAMPLE(2)); check_tick(SAMPLE(3));
        event(false, 69);
        for i in 1 to 16 loop check_tick(0, expect_tail => true); end loop;
        assert saw_tail report "Echo was cut off with note release" severity failure;
        assert held = '0' and active = '0' severity failure;
        echo <= '0'; clocks(1); check_tick(0);
        wait until falling_edge(clk); rst <= '1'; clocks(2);
        buffer_model := (others => 0); pointer := 0;
        wait until falling_edge(clk); rst <= '0'; dist <= '0'; clocks(12);
        event(true, 69, 64);
        for i in 0 to 7 loop check_tick(SAMPLE(i), 64); end loop;
        event(true, 81);
        for i in 0 to 7 loop check_tick(SAMPLE((2 * i) mod 8)); end loop;
        -- Reset flushes both echo history and an in-flight audio transaction.
        wait until falling_edge(clk); tick <= '1'; clocks(1);
        wait until falling_edge(clk); tick <= '0'; rst <= '1'; clocks(2);
        wait until falling_edge(clk); rst <= '0'; clocks(12);
        buffer_model := (others => 0); pointer := 0;
        check_tick(0);
        -- Retrigger immediately before a tick: prefetch is intentionally
        -- incomplete, so emit one zero transaction without raising an error.
        wait until falling_edge(clk);
        note_number <= std_logic_vector(to_unsigned(69, 7));
        velocity <= std_logic_vector(to_unsigned(127, 7)); note_on <= '1';
        wait until falling_edge(clk); note_on <= '0';
        check_tick(0);
        check_tick(SAMPLE(0));
        report "PASS: tb_sampler_core" severity note; stop; wait;
    end process;
    process begin wait for 1 ms; assert false report "tb_sampler_core timeout" severity failure; end process;
end architecture;
