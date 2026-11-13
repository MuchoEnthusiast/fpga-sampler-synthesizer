# FPGA Live Sampler Synthesizer

A modular, monophonic FPGA audio sampler written in **VHDL-2008** for the **Digilent Nexys 4 DDR** (Artix-7 XC7A100T). The FPGA records sound from the board's onboard microphone into sample RAM, then replays it at different pitches using a button or a MIDI keyboard connected through a PC. Playback includes velocity control, a pipelined ADSR envelope, linear interpolation, distortion, and feedback echo.

Developed for the **Advanced Logic Design** course at the **University of Trento**. The real-time audio engine runs on the FPGA; Python tools support MIDI communication, sample preparation, and verification.

## Hardware and audio specifications

| Item | Configuration |
|---|---|
| Board | Digilent Nexys 4 DDR |
| FPGA | Xilinx Artix-7 `xc7a100tcsg324-1` |
| System clock | 100 MHz |
| Language / tools | VHDL-2008, AMD Vivado, Python |
| Audio input | Onboard PDM microphone |
| Audio output | Board audio jack using PWM |
| Sample format / rate | Signed 8-bit PCM / 16 kHz |
| Recording capacity | Up to 16,000 samples (approximately 1 second); minimum 4 samples |
| Sample memory | 16,384 × 8-bit RAM |
| Echo memory | 4,096 × 16-bit RAM (256 ms at 16 kHz) |
| Playback | One voice; looping sample; MIDI notes 48–84 |
| Reference note | MIDI 69 (A4): original sample playback rate |
| PC serial interface | 115200 baud, 8N1 |

## Implemented features

- **Record and replay:** Capture a sound through the onboard microphone. Recording replaces the previous clip, mutes playback, and makes the new clip available only after its final RAM write is committed. Short clips loop at their actual recorded length.
- **Pitch control:** Fixed-point phase accumulation and an indexed pitch-step table transpose the recorded sound. A new note restarts playback from the beginning.
- **Expressive note control:** Monophonic new-note priority, MIDI velocity, sustain pedal (CC64), and panic (CC120/CC123).
- **Pipelined ADSR:** Uses the updated Stage 05 implementation, preserved except for its production entity name, explanatory comment, and line endings. Downstream gain logic honors its registered `gain_valid` timing.
- **Audio processing:** Optional nearest-neighbor or linear interpolation, switchable saturating distortion, feedback echo, and volume control.
- **Modular verification:** Permanent unit and integration testbenches, a shared source manifest, and scripts for simulation and Vivado report collection.

**Scope:** This is a **record-then-play sampler**, not a live voice harmonizer. It does not yet implement simultaneous recording and playback, multiple voices, automatic pitch detection/tuning, pitch bend, time stretching, or score sequencing. Score playback and polyphony remain possible extensions.

The engine changes playback speed relative to the recorded sound. MIDI note 69 reproduces the recording at its original rate; it does **not** automatically tune an arbitrary recorded vowel to A4.

## Architecture

The two main signal paths are:

**Recording:** PDM microphone → PDM capture → CIC decimator → DC removal → recording controller → sample RAM.

**Playback:** UART / buttons → note control and pitch lookup → sample RAM + phase accumulator → interpolation → pipelined ADSR and velocity gain → distortion → feedback echo → PWM audio output.

All internal synchronous logic uses the 100 MHz clock. A 16 kHz clock-enable pulse advances audio processing; pipeline valid signals keep samples and controls aligned. Board-specific pin handling is isolated from the portable audio core.

See [Architecture](docs/architecture.md), [Microphone integration](docs/microphone_integration.md), and [Stage 01–17 migration](docs/migration.md) for detailed block diagrams and timing contracts.

## Repository layout

| Path | Purpose |
|---|---|
| `src/core/common/` | Shared audio types, timing and input synchronization |
| `src/core/control/` | UART command decoding, note events and input arbitration |
| `src/core/memory/` | Sample RAM and recording controller |
| `src/core/audio/` | Microphone DSP, player, pitch, interpolation, ADSR and gain |
| `src/core/effects/` | Distortion and echo |
| `src/core/interfaces/` | UART, PDM capture and PWM |
| `src/platform/nexys4ddr/` | Board-specific top-level wiring |
| `constraints/` | FPGA pin and timing constraints |
| `sim/unit/`, `sim/integration/` | Permanent self-checking VHDL testbenches |
| `samples/` | Audio memory images and test data |
| `tools/` | Python utilities, MIDI bridge, verification and report merger |
| `vivado/` | Reproducible project creation, regression and report scripts |
| `docs/` | Architecture, progress and verification evidence |
| `debug/` | Local, Git-ignored stage experiments (not required by production) |

Production sources and tests do **not** depend on `debug/`. Generated Vivado projects, runs and bitstreams belong under `vivado/build/` and are not version-controlled.

## Verification status

The supplied integration package includes the following **pre-Vivado** evidence:

| Check | Result |
|---|---|
| GHDL 5.0.1 behavioral tests | **29/29 PASS** — 24 testbenches plus five parameter variants |
| Python MIDI-bridge tests | **16 PASS** |
| Independent build-script mock tests | **17 PASS** (not actual Vivado or PowerShell execution) |
| GHDL generic synthesis front end | Passed for the default board top; recognized the 16,384 × 8 sample RAM and 4,096 × 16 echo RAM |
| New integration in Vivado/XSim | **Not yet verified locally** |
| FPGA-mapped utilization, routed timing, CDC and DRC | **Not yet verified locally** |
| Production bitstream and physical board/audio test | **Not yet verified locally** |

The historical Stage 05/07 timing reports are **not** proof that the new integrated design meets 100 MHz timing. Preserve the new XSim results, final implementation reports, and hardware observations separately.

Evidence and exact source hashes are documented in [Verification](docs/verification.md); the ADSR preservation check is described in [Stage 05 ADSR preservation](docs/adsr_preservation.md).

## Build and test with Vivado

On Windows, open the repository in VS Code and run Vivado with no project open. In the **Vivado Tcl Console**:

```tcl
cd {C:/Users/aless/Projects/fpga-sampler-synthesizer}
source vivado/create_project.tcl
source vivado/regression.tcl
```

The regression is expected to finish with **29 passing Vivado cases**. Confirm the actual results before proceeding. In later sessions, open the generated `vivado/build/live_sampler/live_sampler.xpr` instead of recreating it.

Then run synthesis and routed implementation:

```tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
source vivado/export_reports.tcl
```

In the **VS Code PowerShell terminal**, merge the exported reports:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/merge_reports.ps1 `
  -ReportDirectory vivado/build/live_sampler/reports
```

Before generating a bitstream, verify correct constraints, DRC/routing, resource utilization, and setup/hold timing (including WNS ≥ 0 and WHS ≥ 0). Once those checks pass:

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

Use Vivado **Hardware Manager → Open Target → Auto Connect → Program Device** to load the current production bitstream onto the board.

For the full verification procedure, waveform checks, report requirements, and expected paths, follow [Vivado pipeline](docs/vivado_pipeline.md).

## Board controls

| Control | Action |
|---|---|
| `CPU_RESETN` / `BTNC` | Global reset; invalidates any recorded clip |
| `BTNL` | Start recording when microphone-ready LED0 is on |
| `BTND` | Stop recording and panic/mute playback and effects |
| Hold `BTNU` | Audition the clip at note 69, velocity 100 |
| `SW1:SW0` | Volume: `00` full, `01` half, `10` quarter, `11` eighth |
| `SW2` | Enable linear interpolation |
| `SW3` | Enable distortion |
| `SW4` | Distortion drive: ×2 when low, ×4 when high |
| `SW5` | Enable echo |

**LEDs:** LED0 microphone ready; LED1 recording; LED2 valid clip; LED3 note held (including sustain); LED4 ADSR active; LED5 player ready; LED6 sticky pipeline error; LED7 sticky UART framing error; LED8 microphone/DC clipping; LEDs 15:9 current MIDI note.

**First hardware demo:** Wait for LED0 → press BTNL → sing or speak into the onboard microphone → wait for recording to finish (or press BTND) → confirm LED2 → hold BTNU → test interpolation, distortion and echo. Start with low output volume and effects disabled.

## MIDI keyboard and PC bridge

For a USB-MIDI keyboard, connect the keyboard to the PC and the board to the PC through its programming/UART USB port. In PowerShell, from the repository root:

```powershell
py -m pip install -r tools/requirements.txt
py tools/midi_bridge.py list
py -m serial.tools.list_ports
py tools/midi_bridge.py bridge --port COM5 --midi "Exact MIDI input name"
```

Replace `COM5` and the quoted input name with the devices listed on your computer. The PC sends explicit three-byte packets to the FPGA at 115200 baud, 8N1. Only one program can use the COM port at a time; Ctrl+C shuts down the bridge with sustain-off/panic cleanup.

## Development workflow

**Design → Experiment → Simulate → Hardware test → Validate → Integrate → Regression test → Commit.**

Add reusable functionality under the appropriate `src/core/` department, create focused unit tests under `sim/unit/`, and extend `sim/integration/` for interactions. Add new sources and test cases to `vivado/sources.tcl`. Change the board top and XDC only for board-specific connections. Keep experiments in the flat Git-ignored `debug/` folder and preserve verified results in `docs/`.

Track work and measurements in [Project progress](docs/progress.md). Do not replace historical stage evidence with the new integration's preliminary results.
