library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use std.env.all;
entity tb_pdm_decimator is
    generic (DECIMATION : positive := 125; BASE_SHIFT : positive := 14);
end entity;
architecture sim of tb_pdm_decimator is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal bit_in, present : std_logic := '0';
    signal pcm, amplified : signed(7 downto 0);
    signal valid, ready, clipped, amp_valid, amp_ready, amp_clipped : std_logic;
    type integers_t is array(natural range <>) of integer;
    type flags_t is array(natural range <>) of boolean;
    function triangle(n : integer) return integer is
    begin
        if n < 0 then return 0; end if;
        return (n+1)*(n+2)/2;
    end function;
    function coefficient(k : natural) return integer is
    begin
        return triangle(k)-3*triangle(k-DECIMATION)+3*triangle(k-2*DECIMATION)
               -triangle(k-3*DECIMATION);
    end function;
    function rounded(x : integer; shift : positive) return integer is
        variable n : integer := x+2**(shift-1);
    begin
        if n < 0 then return -((-n+2**shift-1)/2**shift); end if;
        return n/2**shift;
    end function;
    function clamp(x : integer) return integer is
    begin
        if x > 127 then return 127; elsif x < -128 then return -128; end if;
        return x;
    end function;
begin
    clk <= not clk after 5 ns;
    dut : entity work.pdm_decimator
        generic map (G_DECIMATION => DECIMATION, G_SHIFT => BASE_SHIFT)
        port map (clk, rst, bit_in, present, pcm, valid, ready, clipped);
    gain4 : entity work.pdm_decimator
        generic map (G_DECIMATION => DECIMATION, G_SHIFT => BASE_SHIFT-2)
        port map (clk, rst, bit_in, present, amplified, amp_valid, amp_ready, amp_clipped);
    process
        -- Independent equivalent FIR: convolution of three length-R boxes.
        -- It uses no CIC wrapping integrators and catches overflow mistakes.
        variable history : integers_t(0 to 3*DECIMATION-3) := (others => 0);
        variable pending : integers_t(0 to 5) := (others => 0);
        variable pending_valid : flags_t(0 to 5) := (others => false);
        variable bit_count, discarded, outputs : natural := 0;
        variable model_ready : boolean := false;
        variable last, last_amp : integer := 0;
        variable positive_peak, negative_peak : integer := 0;
        variable modulator, target : integer := 0;
        variable chosen : std_logic;
        procedure cycle(b, enable : std_logic := '0'; reset : boolean := false) is
            variable sum, normal, boosted : integer;
        begin
            wait until falling_edge(clk);
            bit_in <= b; present <= enable;
            if reset then rst <= '1'; else rst <= '0'; end if;
            wait until rising_edge(clk); wait for 1 ns;
            if reset then
                history := (others => 0); pending := (others => 0);
                pending_valid := (others => false); bit_count := 0; discarded := 0;
                model_ready := false; last := 0; last_amp := 0;
                assert pcm = 0 and amplified = 0 and valid = '0' and amp_valid = '0'
                    and ready = '0' and amp_ready = '0' severity failure;
            else
                if pending_valid(5) then
                    normal := rounded(pending(5), BASE_SHIFT);
                    boosted := rounded(pending(5), BASE_SHIFT-2);
                    assert valid = '1' and amp_valid = '1'
                        report "Missing PCM or incorrect N+6 latency" severity failure;
                    assert to_integer(pcm) = clamp(normal) and to_integer(amplified) = clamp(boosted)
                        report "CIC differs from independent FIR convolution" severity failure;
                    assert (clipped = '1') = (normal > 127 or normal < -128) severity failure;
                    assert (amp_clipped = '1') = (boosted > 127 or boosted < -128) severity failure;
                    model_ready := true; outputs := outputs+1;
                    last := clamp(normal); last_amp := clamp(boosted);
                    if last > positive_peak then positive_peak := last; end if;
                    if last < negative_peak then negative_peak := last; end if;
                else
                    assert valid = '0' and amp_valid = '0' and clipped = '0' and amp_clipped = '0'
                        report "Unexpected or duplicate PCM transaction" severity failure;
                    assert to_integer(pcm) = last and to_integer(amplified) = last_amp severity failure;
                end if;
                assert (ready = '1') = model_ready and (amp_ready = '1') = model_ready severity failure;
                for i in 5 downto 1 loop
                    pending(i) := pending(i-1); pending_valid(i) := pending_valid(i-1);
                end loop;
                pending_valid(0) := false;
                if enable = '1' then
                    for i in history'high downto 1 loop history(i) := history(i-1); end loop;
                    if b = '1' then history(0) := 1; else history(0) := -1; end if;
                    if bit_count = DECIMATION-1 then
                        bit_count := 0; sum := 0;
                        for i in history'range loop sum := sum+history(i)*coefficient(i); end loop;
                        if discarded < 2 then discarded := discarded+1;
                        else pending(0) := sum; pending_valid(0) := true; end if;
                    else bit_count := bit_count+1; end if;
                end if;
            end if;
        end procedure;
        procedure send(b : std_logic) is
        begin cycle(b,'1'); cycle; cycle; end procedure;
    begin
        cycle('0','0',true);
        for mode in 0 to 4 loop
            for n in 0 to 8*DECIMATION-1 loop
                case mode is
                    when 0 => chosen := '1';
                    when 1 => chosen := '0';
                    when 2 => if n mod 2 = 0 then chosen := '1'; else chosen := '0'; end if;
                    when 3 => if n mod 4 = 3 then chosen := '0'; else chosen := '1'; end if;
                    when others => if n mod 4 = 3 then chosen := '1'; else chosen := '0'; end if;
                end case;
                send(chosen);
            end loop;
            for n in 1 to 12 loop cycle; end loop;
        end loop;
        -- First-order PDM modulation of a sinusoid; compare every output
        -- with the FIR oracle while the implementation integrators wrap.
        for n in 0 to 64*DECIMATION-1 loop
            target := integer(16384.0+8192.0*sin(2.0*MATH_PI*real(n)/real(16*DECIMATION)));
            modulator := modulator+target;
            if modulator >= 32768 then chosen := '1'; modulator := modulator-32768;
            else chosen := '0'; end if;
            send(chosen);
        end loop;
        for n in 1 to 20 loop cycle; end loop;
        assert outputs = 102 report "Incorrect number of decimated outputs" severity failure;
        if DECIMATION = 125 and BASE_SHIFT = 14 then
            assert positive_peak = 119 and negative_peak = -119
                report "Original full-scale calibration changed" severity failure;
        end if;
        -- Reset while an accepted last bit still has scheduled arithmetic.
        for n in 1 to DECIMATION loop send('1'); end loop;
        cycle('0','0',true);
        for n in 1 to 10 loop cycle; end loop;
        for n in 1 to 4*DECIMATION loop send('1'); end loop;
        for n in 1 to 10 loop cycle; end loop;
        report "PASS: tb_pdm_decimator" severity note; stop; wait;
    end process;
    process begin wait for 10 ms; assert false report "tb_pdm_decimator timeout" severity failure; end process;
end architecture;
