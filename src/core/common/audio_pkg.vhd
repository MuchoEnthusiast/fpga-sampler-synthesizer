library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package audio_pkg is
    -- Shared supported-note contract; the pitch table is calibrated to root69.
    constant MIDI_MIN_NOTE : natural := 48;
    constant MIDI_MAX_NOTE : natural := 84;
    constant MIDI_ROOT_NOTE : natural := 69;
    subtype pcm8_t is signed(7 downto 0);
    subtype pcm16_t is signed(15 downto 0);
    -- Keep eight fractional bits inside the echo buffer.
    function widen_pcm(x : pcm8_t) return pcm16_t;
    -- Round to nearest, ties away from zero, then saturate to signed PCM8.
    function narrow_pcm(x : pcm16_t) return pcm8_t;
end package;

package body audio_pkg is
    function widen_pcm(x : pcm8_t) return pcm16_t is
    begin
        return shift_left(resize(x, 16), 8);
    end function;

    function narrow_pcm(x : pcm16_t) return pcm8_t is
        variable wide, rounded : signed(16 downto 0);
    begin
        wide := resize(x, 17);
        if wide < 0 then
            rounded := -shift_right(-wide + to_signed(128, 17), 8);
        else
            rounded := shift_right(wide + to_signed(128, 17), 8);
        end if;
        if rounded > 127 then
            return to_signed(127, 8);
        elsif rounded < -128 then
            return to_signed(-128, 8);
        end if;
        return resize(rounded, 8);
    end function;
end package body;
