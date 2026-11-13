# FPGA live sampler and synthesizer

Complete monophonic source implementation for the **Digilent Nexys 4 DDR**, `xc7a100tcsg324-1`, 100 MHz, VHDL-2008. Record the onboard microphone into sample RAM, then play the recording from the audition button or a PC-connected MIDI keyboard with pitch transposition, velocity, ADSR, interpolation, distortion, and feedback echo.

The supplied updated Stage 05 ADSR is preserved exactly apart from its production entity name, first comment, and newline encoding. All production playback uses this implementation and its `gain_valid` pipeline interface.

## Verification status

- **29 VHDL regression cases PASS** with GHDL 5.0.1: 24 self-checking unit/integration benches and five parameter variants.
- **16 Python MIDI bridge tests PASS.**
- **17 independent build-script mock tests PASS.** These do not run Vivado or PowerShell.
- The full default board top passes the GHDL generic synthesis front end. It recognizes the 16,384 x 8 sample RAM and 4,096 x 16 echo RAM.
- **Vivado/XSim, mapped utilization, routed timing/CDC/DRC, bitstream generation, and the physical FPGA/audio test remain to be performed locally.** No new hardware or Vivado result is claimed.

The current evidence and exact source hashes are in [docs/verification.md](docs/verification.md). Historical Stage 05/07 timing reports are clearly separated from this new integration.

## What this instrument does

The default recording limit is 16,000 signed 8-bit samples at 16 kHz, approximately one second. Shorter recordings are supported down to four samples. Recording replaces the previous clip and mutes playback; the completed clip becomes available only after its last RAM write commits. A new note restarts playback at the beginning of the stored clip, which loops while the voice/envelope remains active.

There is one voice with new-note priority, MIDI notes 48–84, sustain pedal CC64, and panic CC120/123. Note 69 plays the recording at its original rate. Other notes transpose relative to it; the design does not detect or correct the recorded source's pitch. Record A4 or provide a correctly rooted sample when conventional keyboard tuning is required. Pitch changes also change playback duration.

This is a record-then-play sampler. It does not implement simultaneous recording/playback, polyphony, automatic tuning, pitch bend, continuous vocal harmonization, or time stretching. Those remain independent future features.

## Start here

1. Read [docs/architecture.md](docs/architecture.md) for the block diagram, ownership, arithmetic, and cycle contracts.
2. Merge these folders into the existing repository, preserving the existing `README.md`, project history, `debug/`, and unrelated files. This separate README avoids replacing the existing one.
3. Follow [docs/vivado_pipeline.md](docs/vivado_pipeline.md) for the complete Windows/Vivado flow, including report merging and acceptance checks before bitstream generation.
4. Read [docs/adsr_preservation.md](docs/adsr_preservation.md) for the exact Stage 05 preservation evidence, and [docs/migration.md](docs/migration.md) for the Stage 01–17 mapping.

No production file depends on `debug/`. All VHDL/XDC files are referenced directly; generated projects and runs belong under `vivado/build/`.

## Board controls

| Control | Function |
|---|---|
| CPU_RESETN / BTNC | Global reset; invalidate a previously recorded clip. |
| BTNL | Begin recording after LED0 indicates microphone readiness. |
| BTND | Stop recording; panic/mute the voice and effects immediately. |
| BTNU, held | Audition the clip at original rate, root note 69, velocity 100. |
| SW1:SW0 | Volume: 00 full, 01 half, 10 quarter, 11 eighth. |
| SW2 | Linear interpolation. |
| SW3 | Distortion enable. |
| SW4 | Distortion drive: low x2, high x4. |
| SW5 | Echo enable. |

LED0 = microphone ready; LED1 = recording; LED2 = valid clip; LED3 = note gate including pedal; LED4 = ADSR active; LED5 = player ready; LED6 = sticky stream error; LED7 = sticky UART framing error; LED8 = microphone/DC clipping since reset or the last record start; LED15:9 = current MIDI note.

Wait for LED0, press BTNL and speak/sing, wait for automatic stop or press BTND, then hold BTNU. The default board starts with no clip. The audio jack is the output; acquisition uses the onboard microphone.

## PC MIDI bridge

Use PowerShell at the repository root:

```powershell
py -m pip install -r tools/requirements.txt
py tools/midi_bridge.py list
py tools/midi_bridge.py bridge --port COM5 --midi "Exact MIDI input name"
```

Replace the port/name with the listed devices. The keyboard plugs into the PC, and the PC forwards explicit three-byte packets to the FPGA at 115200 baud, 8N1. Ctrl+C performs sustain-off/panic cleanup. Only one process may own the serial port at a time.

## Permanent development flow

Add a reusable feature in its relevant `src/core/` department and normally add its own `sim/unit/` bench. Extend the appropriate `sim/integration/` bench for interactions. Modify `sampler_core` for audio integration and the board top for actual new board connections. Add paths and parameter cases to `vivado/sources.tcl`; both simulator runners use that manifest.

Keep `/debug/`, `/vivado/build/`, generated simulation/cache/run directories, logs, checkpoints, and bitstreams out of Git. Preserve curated verification evidence in `docs/verification/`. Merge the supplied [progress entry](docs/progress.md) into existing history rather than erasing earlier entries.
