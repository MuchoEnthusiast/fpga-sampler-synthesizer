library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
entity tb_note_event_manager is end entity;
architecture sim of tb_note_event_manager is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal note_on_i, note_off_i : std_logic := '0';
    signal note_i, velocity_i, note_o : std_logic_vector(6 downto 0) := (others => '0');
    signal velocity_o : unsigned(6 downto 0);
    signal step_o : unsigned(17 downto 0);
    signal held, started, released : std_logic;
    signal pedal, panic_i : std_logic := '0';
begin
    clk <= not clk after 5 ns;
    dut : entity work.note_event_manager port map (
        clk => clk, rst => rst, note_on_i => note_on_i, note_off_i => note_off_i,
        note_number_i => note_i, velocity_i => velocity_i,
        note_number_o => note_o, velocity_o => velocity_o, step_o => step_o,
        held_o => held, start_pulse_o => started, release_pulse_o => released,
        sustain_pedal => pedal, panic => panic_i
    );
    watchdog : process begin
        wait for 100 us;
        assert false report "tb_note_event_manager timeout" severity failure;
    end process;
    stimulus : process
        procedure event(n, v : natural; on_event, off_event : std_logic) is
        begin
            wait until falling_edge(clk);
            note_i <= std_logic_vector(to_unsigned(n, 7));
            velocity_i <= std_logic_vector(to_unsigned(v, 7));
            note_on_i <= on_event; note_off_i <= off_event;
            wait until rising_edge(clk); wait for 1 ns;
        end procedure;
        procedure idle is
        begin
            event(0, 0, '0', '0');
            assert started = '0' and released = '0'
                report "Control outputs are not one-clock pulses" severity failure;
        end procedure;
        variable expected_step : integer;
    begin
        wait until rising_edge(clk); wait for 1 ns;
        assert unsigned(note_o) = 69 and step_o = 65536 and velocity_o = 0 and held = '0'
            report "Note manager reset mismatch" severity failure;
        rst <= '0';
        for n in 48 to 84 loop
            event(n, 100, '1', '0');
            expected_step := integer(floor(65536.0 * 2.0**(real(n - 69) / 12.0) + 0.5));
            assert to_integer(step_o) = expected_step
                report "Pitch LUT mismatch for note " & integer'image(n) severity failure;
            assert unsigned(note_o) = n and velocity_o = 100 and held = '1' and started = '1'
                report "Note-on metadata mismatch" severity failure;
            idle;
        end loop;
        event(47, 80, '1', '0');
        assert unsigned(note_o) = 84 and started = '0' severity failure;
        event(85, 80, '1', '0');
        assert unsigned(note_o) = 84 and started = '0' severity failure;
        event(69, 127, '1', '0');
        assert step_o = 65536 and started = '1' severity failure;
        idle;
        event(60, 0, '0', '1');
        assert held = '1' and released = '0' report "Unmatched off stopped note" severity failure;
        event(69, 0, '0', '1');
        assert held = '0' and released = '1' report "Matching off failed" severity failure;
        idle;
        event(69, 0, '0', '1');
        assert released = '0' report "Repeated off retriggered release" severity failure;
        event(57, 90, '1', '1'); -- note-on priority
        assert step_o = 32768 and held = '1' and started = '1' and released = '0' severity failure;
        idle;
        event(81, 70, '1', '0');
        assert step_o = 131072 and velocity_o = 70 severity failure;
        event(57, 0, '0', '1');
        assert held = '1' and unsigned(note_o) = 81 severity failure;
        -- Sustain retains a released current note until pedal-up.
        idle; pedal <= '1';
        event(81, 0, '0', '1');
        assert held = '1' and released = '0' report "Pedal did not hold released key" severity failure;
        idle;
        pedal <= '0'; event(0, 0, '0', '0');
        assert held = '0' and released = '1' report "Pedal-up did not release sustained note" severity failure;
        -- Pedal-up while the physical key is down must leave it sounding.
        pedal <= '1'; event(69, 100, '1', '0'); idle;
        pedal <= '0'; idle;
        assert held = '1' severity failure;
        -- A new note replaces a sustained note; old note-off is ignored.
        pedal <= '1'; event(69, 0, '0', '1');
        event(72, 90, '1', '0'); idle;
        event(69, 0, '0', '1');
        assert held = '1' and unsigned(note_o) = 72 and released = '0' severity failure;
        event(72, 0, '0', '1');
        assert held = '1' severity failure;
        -- Panic always wins over simultaneous note-on, even with sustain.
        panic_i <= '1'; event(81, 100, '1', '0');
        assert held = '0' and released = '1' and started = '0' severity failure;
        panic_i <= '0'; idle; pedal <= '0';
        event(69, 100, '1', '0'); idle;
        event(69, 0, '1', '0'); -- defensive direct zero-velocity handling
        assert held = '0' and released = '1' severity failure;
        idle;
        rst <= '1';
        wait until rising_edge(clk); wait for 1 ns;
        assert held = '0' and started = '0' and released = '0' and velocity_o = 0 severity failure;
        report "PASS: tb_note_event_manager" severity note;
        stop; wait;
    end process;
end architecture;
