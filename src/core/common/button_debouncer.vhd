library ieee;
use ieee.std_logic_1164.all;

-- Input has already crossed a two-register synchronizer. Accept a new level
-- only after STABLE_CYCLES consecutive differing samples. Emit one rising
-- pulse on a debounced press; holding the button does not repeat the pulse.
entity button_debouncer is
    generic (STABLE_CYCLES : positive := 500_000);
    port (
        clk, rst, button_i : in std_logic;
        level_o, pressed_o : out std_logic
    );
end entity;
architecture rtl of button_debouncer is
    signal stable_q, pulse_q : std_logic := '0';
    signal count : natural range 0 to STABLE_CYCLES-1 := 0;
begin
    level_o <= stable_q;
    pressed_o <= pulse_q;
    process(clk)
    begin
        if rising_edge(clk) then
            pulse_q <= '0';
            if rst = '1' then stable_q <= '0'; count <= 0;
            elsif button_i = stable_q then count <= 0;
            elsif count = STABLE_CYCLES-1 then
                stable_q <= button_i; count <= 0;
                if button_i = '1' then pulse_q <= '1'; end if;
            else count <= count+1; end if;
        end if;
    end process;
end architecture;
