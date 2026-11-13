library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Stage 08 arithmetic, promoted without a change in behavior.
-- Accepted input at edge N -> output and valid immediately after edge N.
-- Bypass has the same latency. Invalid clocks hold PCM and clear valid.
entity distortion is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        in_valid_i  : in  std_logic;
        pcm_i       : in  signed(7 downto 0);
        enable_i    : in  std_logic;
        drive4_i    : in  std_logic;
        pcm_o       : out signed(7 downto 0);
        out_valid_o : out std_logic
    );
end entity;

architecture rtl of distortion is
    signal pcm_q   : signed(7 downto 0) := (others => '0');
    signal valid_q : std_logic := '0';
begin
    process(clk)
        variable driven : integer range -512 to 508;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pcm_q <= (others => '0');
                valid_q <= '0';
            else
                valid_q <= in_valid_i;
                if in_valid_i = '1' then
                    if enable_i = '0' then
                        pcm_q <= pcm_i;
                    else
                        if drive4_i = '1' then
                            driven := 4 * to_integer(pcm_i);
                        else
                            driven := 2 * to_integer(pcm_i);
                        end if;
                        if driven > 127 then
                            pcm_q <= to_signed(127, 8);
                        elsif driven < -128 then
                            pcm_q <= to_signed(-128, 8);
                        else
                            pcm_q <= to_signed(driven, 8);
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;
    pcm_o <= pcm_q;
    out_valid_o <= valid_q;
end architecture;
