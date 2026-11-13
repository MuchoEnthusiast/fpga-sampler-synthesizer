# Preserving the updated Stage 05 ADSR

The updated upload contains the already pipelined `05_ADSR_envelope.vhd`. The production `src/core/audio/adsr_envelope.vhd` preserves its RTL exactly. Only the entity name (`dbg_adsr_envelope` to `adsr_envelope`), the first explanatory comment, and text newline encoding changed. The previous integration candidate's different four-register implementation is replaced by this uploaded implementation.

[preservation.json](verification/adsr_reference/preservation.json) records the original and production SHA-256 hashes and the successful normalized-content equality check. [renaming.diff](verification/adsr_reference/renaming.diff) shows the complete textual change. The original file is archived for evidence only; no production source list depends on it.

## Pipeline contract

- Edge N: update the envelope FSM/progress and register interpolation operands plus status.
- Edge N+1: register the 16-by-16 product and matching metadata.
- Edge N+2: publish `gain_out`, `active_out`, `done_pulse`, and `gain_valid` together.
- Minimum separation between accepted `sample_tick` pulses: three system clock cycles.
- Reset clears the complete arithmetic pipeline and pending note event.

This module already exposes `gain_valid`; integration must use it rather than assuming the gain changes on the input tick. There is no `ready_out` port. A 16 kHz sample interval at 100 MHz leaves 6,250 clocks between updates.

The original self-checking pipelined bench was promoted and extended with a watchdog, minimum-rate clamp check, simultaneous and pending event priority, an event during in-flight arithmetic, and reset cancellation before N+2. [Its GHDL log](verification/control/tb_adsr_envelope.log) records PASS. The bench's regular calls use the minimum three-clock tick interval and retain the original exact envelope values and 65,535-update boundary test.

## Uploaded historical timing evidence

| Uploaded report | Setup WNS | Hold WHS | Requirement |
|---|---:|---:|---:|
| [Stage 05 pipelined implementation](verification/adsr_reference/05_ADSR_pipelined_impl_timing.rpt) | +0.205 ns | +0.035 ns | 10 ns |
| [Stage 05 corrected board implementation](verification/adsr_reference/05_ADSR_hw_corrected_timing.rpt) | +0.521 ns | +0.167 ns | 10 ns |
| [Stage 07 integrated implementation](verification/adsr_reference/07_INTEGRATION_impl_1_timing.rpt) | +0.184 ns | +0.152 ns | 10 ns |

These are results from the supplied historical runs. They show why the validated pipeline should be preserved. They do not establish timing closure for this new live-sampler integration; its Vivado synthesis, placement, routing, CDC and DRC checks remain required.

## Note and sustain control extension

The FPGA link preserves complete three-byte note packets and adds `B0 controller value`. CC64 values 64–127 mean sustain down; 0–63 mean up. CC120 and CC123 produce a one-clock panic and clear sustain. Unsupported controllers and unsupported status bytes are ignored. A framing error discards a partial packet.

The monophonic note manager retains the existing MIDI 48–84 pitch table and A4 root69. A new valid note replaces the current note; it does not keep a stack of older held keys. Matching note-off while sustain is down releases the physical key but keeps the voice gate high. Pedal-up releases that gate only after the key has been released. `held_o` therefore includes pedal-held notes. Panic takes priority over note events. The board/core integration can use panic to flush gain and effects immediately.

[UART/control](verification/control/tb_uart_control.log) and [note manager](verification/control/tb_note_event_manager.log) checks pass with the new controller semantics while retaining the previous note protocol checks.

## PC keyboard bridge

`tools/midi_bridge.py` is migrated from Stage17. It forwards note events, sustain, CC120 and CC123; all output packets include their channel-zero status byte. `panic` and bridge shutdown send sustain-off first, then all-sound-off, then 128 explicit legacy note-offs. `tools/test_midi_bridge.py` passes 16 tests without MIDI or serial dependencies; [the log](verification/control/midi_bridge.log) is included. Real Windows MIDI/USB-UART communication remains a hardware integration check.

Install `tools/requirements.txt`, list ports, and use the exact reported device name:

```powershell
py -m pip install -r tools/requirements.txt
py tools/midi_bridge.py list
py tools/midi_bridge.py bridge --port COM5 --midi "Your keyboard name"
py tools/midi_bridge.py pedal --port COM5 --value 127
py tools/midi_bridge.py pedal --port COM5 --value 0
py tools/midi_bridge.py panic --port COM5
py tools/test_midi_bridge.py
```

Mido's documented input iteration and `control_change` message fields are used: https://mido.readthedocs.io/en/stable/api.html and https://mido.readthedocs.io/en/latest/messages/ . No MIDI clock, pitch-bend, aftertouch, running status, or polyphonic voice allocation is implied by this bridge.
