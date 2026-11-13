library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;
use work.audio_pkg.all;

-- Actual record controller/RAM/player/ADSR/gain/effects integration, using
-- independent integer arithmetic and recorded data rather than a ROM fixture.
entity tb_live_sampler is end entity;
architecture sim of tb_live_sampler is
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal tick, on_event, off_event, dist, drive4, echo : std_logic := '0';
    signal rec_start, rec_stop, rec_valid, pedal, panic : std_logic := '0';
    signal note_number : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(69,7));
    signal velocity : std_logic_vector(6 downto 0) := std_logic_vector(to_unsigned(127,7));
    signal volume : unsigned(1 downto 0) := "00";
    signal rec_pcm, pcm : pcm8_t := (others => '0');
    signal valid, held, active, ready, error_flag, recording, clip_ready, done : std_logic;
    signal current_note : std_logic_vector(6 downto 0);
    signal length, count : unsigned(4 downto 0);
    type integers_t is array(natural range <>) of integer;
    constant CLIP : integers_t(0 to 7) := (100,64,-100,-64,20,-20,127,-128);
    constant SHORT_CLIP : integers_t(0 to 4) := (12,78,-34,-100,116);
    function floordiv(a : integer; b : positive) return integer is
    begin
        if a < 0 then return -((-a+b-1)/b); end if;
        return a/b;
    end function;
    function clipto(a,lo,hi : integer) return integer is
    begin
        if a<lo then return lo; elsif a>hi then return hi; end if;
        return a;
    end function;
    function interpolated(a,b,fraction : integer) return integer is
        variable product,delta : integer;
    begin
        product := (b-a)*fraction;
        if product<0 then delta := -((-product+32768)/65536);
        else delta := (product+32768)/65536; end if;
        return clipto(a+delta,-128,127);
    end function;
begin
    clk <= not clk after 5 ns;
    dut : entity work.sampler_core
        generic map (ADDR_BITS=>4,SAMPLE_COUNT=>8,INIT_FILE=>"",PRELOADED_SAMPLES=>0,
                     ECHO_DELAY_SAMPLES=>4,ATTACK_RATE_G=>x"00000000",
                     DECAY_RATE_G=>x"00000000",SUSTAIN_G=>x"8000",RELEASE_RATE_G=>x"00000000")
        port map (clk=>clk,rst=>rst,sample_tick=>tick,note_on=>on_event,note_off=>off_event,
                  note_number=>note_number,velocity=>velocity,linear_mode=>'1',
                  distortion_enable=>dist,distortion_drive4=>drive4,echo_enable=>echo,
                  pcm_out=>pcm,pcm_valid=>valid,current_note=>current_note,note_held=>held,
                  envelope_active=>active,player_ready=>ready,stream_error=>error_flag,
                  record_start=>rec_start,record_stop=>rec_stop,record_pcm_valid=>rec_valid,
                  record_pcm=>rec_pcm,sustain_pedal=>pedal,panic=>panic,volume_shift=>volume,
                  recording=>recording,sample_ready=>clip_ready,record_done=>done,
                  sample_length=>length,recorded_count=>count);
    stimulus : process
        variable echo_model : integers_t(0 to 3) := (others=>0);
        variable pointer : natural range 0 to 3 := 0;
        variable phase,raw : integer := 0;
        variable saw_tail : boolean := false;
        procedure clocks(n : positive) is
        begin
            for i in 1 to n loop wait until rising_edge(clk); wait for 1 ns; end loop;
        end procedure;
        procedure pulse(signal s : out std_logic) is
        begin
            wait until falling_edge(clk); s<='1';
            wait until falling_edge(clk); s<='0';
        end procedure;
        procedure note(is_on : boolean; n : natural; v : natural:=127) is
        begin
            wait until falling_edge(clk);
            note_number<=std_logic_vector(to_unsigned(n,7));
            velocity<=std_logic_vector(to_unsigned(v,7));
            if is_on then on_event<='1'; else off_event<='1'; end if;
            wait until falling_edge(clk); on_event<='0'; off_event<='0'; clocks(12);
        end procedure;
        procedure start_record is
        begin
            pulse(rec_start); clocks(1);
            assert recording='1' and clip_ready='0' and held='0' and pcm=0
                report "Record start failed to invalidate/mute" severity failure;
            echo_model:=(others=>0); pointer:=0;
        end procedure;
        procedure write_pcm(x : integer) is
        begin
            wait until falling_edge(clk); rec_valid<='1'; rec_pcm<=to_signed(x,8);
            clocks(1); wait until falling_edge(clk); rec_valid<='0'; clocks(2);
        end procedure;
        procedure stop_record is
        begin
            pulse(rec_stop); clocks(12);
        end procedure;
        procedure reset_audio is
        begin
            pulse(panic); clocks(12); echo_model:=(others=>0); pointer:=0;
            assert held='0' and active='0' and pcm=0 and clip_ready='1'
                report "Panic must mute audio while retaining the clip" severity failure;
        end procedure;
        procedure check_tick(x : integer; v : natural:=127; tail : boolean:=false;
                             change_controls : boolean:=false) is
            variable coeff,dry,mixed,scaled,expected : integer;
        begin
            coeff:=v; if v=127 then coeff:=128; end if;
            dry:=floordiv(x*coeff,256); -- actual envelope code is32768.
            if dist='1' then
                if drive4='1' then dry:=clipto(dry*4,-128,127);
                else dry:=clipto(dry*2,-128,127); end if;
            end if;
            mixed:=clipto(dry*256+floordiv(echo_model(pointer),2),-32768,32767);
            echo_model(pointer):=mixed; pointer:=(pointer+1) mod 4;
            if echo='0' then mixed:=dry*256; end if;
            scaled:=floordiv(mixed,2**to_integer(volume));
            if scaled<0 then expected:=-((-scaled+128)/256);
            else expected:=(scaled+128)/256; end if;
            expected:=clipto(expected,-128,127);
            wait until falling_edge(clk); tick<='1'; clocks(1); tick<='0';
            assert valid='0' severity failure;
            if change_controls then volume<="11"; dist<=not dist; echo<=not echo; end if;
            for age in 1 to 15 loop
                clocks(1);
                if age=9 then
                    assert valid='1' and to_integer(pcm)=expected
                        report "Live output value/latency: expected " & integer'image(expected) &
                               " got " & integer'image(to_integer(pcm)) severity failure;
                    if tail and expected/=0 then saw_tail:=true; end if;
                else assert valid='0' report "Unexpected output transaction" severity failure; end if;
                assert error_flag='0' report "Live stream error" severity failure;
            end loop;
        end procedure;
    begin
        clocks(3); wait until falling_edge(clk); rst<='0'; clocks(12);
        assert clip_ready='0' and length=0 and pcm=0 severity failure;
        note(true,69); pulse(tick); clocks(16);
        assert held='0' and valid='0' and pcm=0 report "Empty memory played" severity failure;
        start_record;
        for i in CLIP'range loop write_pcm(CLIP(i)); end loop;
        clocks(12);
        assert recording='0' and clip_ready='1' and length=8 and count=8
            report "Full recording metadata mismatch" severity failure;
        note(true,69);
        for i in 0 to 15 loop check_tick(CLIP(i mod 8)); end loop;
        pedal<='1'; clocks(2); note(false,69);
        assert held='1' report "Pedal did not retain released note" severity failure;
        for i in 0 to 3 loop check_tick(CLIP(i)); end loop;
        pedal<='0'; clocks(12); check_tick(0);
        assert held='0' and active='0' severity failure;

        reset_audio; note(true,57,64); phase:=0;
        for i in 0 to 15 loop
            volume<=to_unsigned(i mod 4,2); clocks(1);
            raw:=interpolated(CLIP(phase/65536),CLIP((phase/65536+1) mod 8),phase mod 65536);
            check_tick(raw,64); phase:=(phase+32768) mod (8*65536);
        end loop;
        -- Captured controls must remain associated with an in-flight sample.
        volume<="00"; clocks(1); check_tick(CLIP(0),64,change_controls=>true);
        volume<="00"; dist<='0'; echo<='0'; clocks(1);
        -- Panic cancels the entire in-flight transaction, including echo.
        wait until falling_edge(clk); tick<='1'; clocks(1);
        wait until falling_edge(clk); tick<='0'; panic<='1'; clocks(1);
        wait until falling_edge(clk); panic<='0';
        for i in 1 to 16 loop clocks(1); assert valid='0' and pcm=0 severity failure; end loop;
        assert clip_ready='1' and held='0' severity failure;

        start_record;
        for i in SHORT_CLIP'range loop write_pcm(SHORT_CLIP(i)); end loop;
        stop_record;
        assert clip_ready='1' and length=5 and count=5 report "Short recording metadata mismatch" severity failure;
        note(true,81);
        for i in 0 to 14 loop check_tick(SHORT_CLIP((2*i) mod 5)); end loop;

        start_record;
        for i in 0 to 2 loop write_pcm(127); end loop;
        stop_record;
        assert clip_ready='0' and length=0 report "Invalid short clip accepted" severity failure;
        note(true,69); pulse(tick); clocks(16);
        assert held='0' and valid='0' and pcm=0 severity failure;

        start_record;
        for i in CLIP'range loop write_pcm(CLIP(i)); end loop;
        clocks(12); note(true,69);
        dist<='1'; drive4<='1'; echo<='1'; volume<="00"; clocks(1);
        for i in 0 to 7 loop check_tick(CLIP(i)); end loop;
        note(false,70); assert held='1' severity failure;
        check_tick(CLIP(0)); note(false,69);
        for i in 1 to 20 loop check_tick(0,tail=>true); end loop;
        assert saw_tail report "Release cut off the echo tail" severity failure;
        reset_audio;
        for i in 1 to 9 loop check_tick(0); end loop;
        assert error_flag='0' severity failure;
        report "PASS: tb_live_sampler" severity note; stop; wait;
    end process;
    process begin wait for 1 ms; assert false report "tb_live_sampler timeout" severity failure; end process;
end architecture;
