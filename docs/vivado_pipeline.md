# Vivado pipeline and board operation

This is the reproducible flow for the live sampler on the Nexys 4 DDR,
`xc7a100tcsg324-1`, with a 100 MHz system clock. Production sources live in
`src/`; the project references them directly. Nothing under `debug/` is needed.
The generated project is separate from earlier experiments:

`vivado/build/live_sampler/live_sampler.xpr`

The provided RTL regression evidence was produced with GHDL. Vivado/XSim,
Vivado synthesis and routing, PowerShell report merging, and the physical
board still need to be run on your Windows installation. The build-script
mock tests check control flow and error handling; they do not establish that
Vivado has accepted or implemented this design.

## 1. Prepare and create the project

Place the production folders in your repository, preserving your existing
experimental files and reports. Keep `src/`, `sim/`, `samples/`, `constraints/`,
`tools/`, `docs/`, and `vivado/*.tcl` under version control. Ignore generated
`vivado/build/` content. The authoritative compile order is
`vivado/sources.tcl`: 23 RTL files, 24 benches, two memory fixtures, and five
additional parameter cases.

Start Vivado with no project open. In **Tcl Console**, change this example
path to your repository:

```tcl
cd {C:/Projects/fpga-sampler-synthesizer}
source vivado/create_project.tcl
```

The script chooses the FPGA part directly, marks every VHDL file as VHDL-2008,
sets `top_nexys4ddr` as the design top and `tb_top_nexys4ddr` as the simulation
top, and adds the board XDC. It refuses to overwrite an existing project.
On later visits, use **Open Project** or:

```tcl
open_project vivado/build/live_sampler/live_sampler.xpr
```

The `.mem` files are small initialization fixtures used by specific benches.
The default live-board design starts without a recorded clip;
`INIT_FILE=""` and `PRELOADED_SAMPLES=0`. Memory fixtures are staged only into
known generated project/run/simulation directories. They are present before
elaboration; they must not be manually copied into the repository root.

## 2. Run behavioral verification

### Complete automated XSim regression

Close any interactive simulation first. With the live-sampler project open
and the Tcl working directory at the repository root, run:

```tcl
source vivado/regression.tcl
```

The script runs every unit and integration bench. It also runs the echo
with depths 1 and 4, the recorder at its full 16-address test depth, and the
CIC at decimations 1 and 5. These five cases are read from the same manifest
as the GHDL runner.

For each case, the script generates the simulator scripts, refreshes memory
fixtures, then runs compile, elaborate, and simulate. It requires a fresh
`PASS: <bench>` marker and rejects failing processes and reported errors.
An old log containing PASS cannot satisfy a new test. Each invocation gets
its own timestamped evidence directory below:

`vivado/build/live_sampler/regression/`

The expected final message is:

```text
PASS: all 29 Vivado regression cases (24 benches). Logs: ...
```

The previous simulation top, generic overrides, custom simulation Tcl, and
working directory are restored even when a case fails. If a test fails,
inspect that case's `case.txt`, `compile.console.log`,
`elaborate.console.log`, `simulate.console.log`, and archived tool logs.
Correct the failing behavior before continuing to synthesis.

For batch use, open the Vivado command prompt, change to the repository
directory, and run:

```bat
vivado -mode batch -source vivado/regression.tcl
```

The project must already have been created. AMD documents the generated
compile/elaborate/simulate scripts and the flags used here in
[UG835: launch_simulation](https://docs.amd.com/r/2023.1-English/ug835-vivado-tcl-commands/launch_simulation).
The custom `run all` script uses the documented
[XSim custom Tcl property](https://docs.amd.com/r/2025.1-English/ug900-vivado-logic-simulation/Vivado-Simulator-Simulation-Options).

### Inspect waveforms

Use `tb_microphone` for the acquisition chain, `tb_record_playback` for RAM
record/commit/playback, `tb_live_sampler` for recorded-PCM-to-playback
integration, and `tb_top_nexys4ddr` for the complete microphone path, board
controls, and UART ownership.

For example, in Tcl Console:

```tcl
set_property top tb_live_sampler [get_filesets sim_1]
set_property generic {} [get_filesets sim_1]
set_property xsim.simulate.custom_tcl {} [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
source vivado/stage_memory.tcl
launch_simulation -simset sim_1 -mode behavioral -noclean_dir
```

In the simulation window, select the relevant DUT scope, select its signals
in **Objects**, and choose **Add to Wave Window**. Use **Restart** and
**Run All**. Save the waveform configuration for your report. When finished,
close the simulation and restore the default top:

```tcl
close_sim
set_property top tb_top_nexys4ddr [get_filesets sim_1]
set_property generic {} [get_filesets sim_1]
update_compile_order -fileset sim_1
```

Verify the following relationships, using the assertions as the primary
behavioral checks:

| Relationship | Expected behavior |
|---|---|
| Microphone clock | 2 MHz from the 100 MHz clock; M_LRSEL low. |
| Filter output | One signed-8 PCM sample every 6,250 system clocks after startup. |
| Record arbitration | Recording mutes playback; only valid microphone samples write RAM. |
| Last recorded sample | Metadata becomes available after the final RAM write has committed. |
| ADSR pipeline | Updated Stage 05 gain and valid appear together two clocks after its accepted tick. |
| Audio output pipeline | PCM output follows a core playback tick by nine clocks during normal steady operation. |
| Reset/panic | Pending audio operations are flushed; no old sample should reappear. |
| Stream diagnostics | `stream_error` remains low in valid operating sequences. |

Some integration benches deliberately accelerate warmup or sample timing
and use a smaller RAM. `tb_microphone` retains the actual 100 MHz / 2 MHz /
16 kHz rate relationship. Simulation timing is not a measurement of board
electrical timing.

### Optional GHDL and Python checks

From PowerShell at the repository root, with GHDL installed:

```powershell
py tools/run_ghdl.py
py tools/run_ghdl.py --test tb_live_sampler
py tools/run_ghdl.py --test tb_pdm_decimator
py tools/run_ghdl.py --test tb_record_controller_full_depth
py tools/test_midi_bridge.py
```

Use `--ghdl C:/path/to/ghdl.exe` if it is not on PATH. Selecting a base bench
also selects its manifest variants. The GHDL runner retains fresh logs,
source and manifest hashes, tool version, and `results.json` below
`vivado/build/ghdl/`. The Python bridge tests require no connected hardware.
`tools/test_build_flow.py` is an additional mock check requiring `tclsh` and
`bash`; it is not an XSim or FPGA test.

## 3. Synthesize

Ensure the synthesis top still reads `top_nexys4ddr`. In **Flow Navigator**,
choose **Run Synthesis** and wait until the run completes. The Tcl equivalent
is:

```tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
get_property STATUS [get_runs synth_1]
get_property NEEDS_REFRESH [get_runs synth_1]
```

`wait_on_run` is intended for scripts/batch operation and may be ignored in
the interactive GUI; in the GUI, wait for completion in **Design Runs**
before entering the next step. A completed wait alone does not prove that
the run succeeded. Require `synth_design Complete!` and a false
`NEEDS_REFRESH`, then review **Messages**, inferred memories, utilization,
and warnings. See AMD's
[run/wait documentation](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/wait_on_runs).

The capture RAM should infer block RAM and retain a synchronous read port.
Inspect the hierarchical utilization for sample RAM, echo RAM, arithmetic,
and DSP mapping. Look for unintended latches, accidental RAM reset loops,
arithmetic-width warnings, or missing constraints. Exact resource counts
must come from your run; no estimates replace this check.

If production sources changed after a previous run, use **Reset Run** for
the affected synthesis/implementation runs before launching again. A reset
of a generated run does not change repository sources. Do not accept a
stale result from an earlier revision.

## 4. Implement through routing

In **Flow Navigator**, choose **Run Implementation** and wait for routing to
complete. The scripted equivalent is:

```tcl
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
get_property STATUS [get_runs impl_1]
get_property NEEDS_REFRESH [get_runs impl_1]
```

Require `route_design Complete!` and false `NEEDS_REFRESH`. Stop here for
report review. AMD documents this step boundary in
[UG835: launch_runs](https://docs.amd.com/r/2023.2-English/ug835-vivado-tcl-commands/launch_runs).

The project uses one internal clock at 100 MHz. M_CLK is a registered board
output, not an additional fabric clock. Review the XDC's targeted
asynchronous-input exceptions: only the path into each first receiving
register is cut, and the path between synchronizer registers remains timed.
The XDC deliberately checks the expected first-stage register names/counts;
if that check fails, inspect the synthesized hierarchy and repair the
specific constraint instead of deleting the check.

## 5. Export, merge, and verify reports

After both runs are complete and current, from the repository root in Tcl
Console:

```tcl
source vivado/export_reports.tcl
```

This script opens the stored synthesis and implementation results. It
rejects stale/incomplete runs and creates exactly 14 report inputs in:

`vivado/build/live_sampler/reports/`

They include source-path/time/part/top/run provenance; synthesis and routed
utilization, timing, and DRC; both run logs; and routing, I/O, clocks, CDC,
and methodology reports. The export does not launch runs or generate a
bitstream. Save any deliberate edits to an interactively opened design
before export, because export opens the stored runs.

In PowerShell at the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/merge_reports.ps1 `
  -ReportDirectory vivado/build/live_sampler/reports
```

The result is `vivado/build/live_sampler/reports/merged_reports.txt`. The
merger requires all 14 inputs and preserves their fixed order. Archive this
bundle with the source revision and the regression logs used for that build.

Review these acceptance checks before generating a bitstream:

| Evidence | Required review |
|---|---|
| Routed timing | Setup WNS >= 0 and TNS = 0; hold WHS >= 0 and THS = 0; no pulse-width failures. |
| Timing coverage | One 10 ns system clock; no unexplained internal unconstrained paths; examine all timing-check warnings. |
| Exceptions/CDC | Expected synchronizers remain present; only intended external-to-first-register paths are excluded; explain each reported crossing. |
| External I/O | Correct board pins and LVCMOS33; microphone phase checked against the board interface. LEDs/audio/control outputs have no synchronous external receiver model. Document that external timing coverage. |
| Routing | All required nets routed; no routing errors or shorts. |
| DRC/methodology | No errors; resolve or explicitly justify every warning relevant to this design. |
| Resources | LUT/FF/BRAM/DSP/clock resources fit the actual FPGA; inspect inferred RAM and arithmetic placement. |
| Provenance | Correct part, top, source paths, run status, and source revision. |

Positive internal WNS does not prove physical microphone sampling margin
or audio quality. Validate those on the board. Historical Stage 05/07
reports remain historical evidence; they are not timing reports for this
new integration.

## 6. Generate the bitstream and program

After the preceding checks pass, choose **Generate Bitstream**, or:

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
get_property STATUS [get_runs impl_1]
```

Require `write_bitstream Complete!`. The expected file is:

`vivado/build/live_sampler/live_sampler.runs/impl_1/top_nexys4ddr.bit`

Connect and power the Nexys 4 DDR using its programming/UART USB connection.
Choose **Open Hardware Manager -> Open Target -> Auto Connect**. Select the
XC7A100T device, choose **Program Device**, select this exact `.bit`, and
program it. If several devices are connected, select the actual Nexys board
by its hardware target before programming. No flash-memory programming is
required for this development loop.

## 7. Record and play a live sample

The input is the board's onboard PDM microphone. The audio connector is used
for playback. Start with effects disabled and volume reduced. The default
microphone path runs continuously; it waits 50 ms after reset and discards
the first two decimator outputs before declaring readiness.

| Control | Function |
|---|---|
| CPU_RESETN or BTNC | Reset control/audio state. A previously recorded clip is invalidated and must be recorded again. |
| BTNL | Start a new recording once microphone-ready is high; this replaces the previous clip. |
| BTND | Stop recording and immediately panic/mute the playback voice/effects. |
| BTNU, held | Audition the current clip at its original playback rate, root note 69, velocity 100. Release starts the normal ADSR release, unless the pedal is holding the voice. |
| SW1:SW0 | Output shift: 00 full, 01 half, 10 quarter, 11 eighth amplitude. |
| SW2 | Enable linear interpolation. |
| SW3 | Enable distortion. |
| SW4 | Select higher distortion drive when distortion is enabled. |
| SW5 | Enable echo. |

1. Program the device and wait for LED0. LED2 starts low because no clip is loaded by default.
2. Press BTNL and speak or sing into the onboard microphone. LED1 indicates recording.
3. Recording stops automatically after 16,000 accepted samples (about one second), or press BTND to stop earlier. A valid clip needs at least four samples. LED2 indicates a completed usable clip.
4. Hold BTNU to audition. Release it to hear the ADSR release. Use BTND for immediate silence.
5. Try interpolation, distortion/drive, and echo separately, then in combination. For a new sample, press BTNL again.

Buttons use a 5 ms debounce interval. A press during microphone startup is
ignored; press again after LED0. Recording suppresses playback and note
events. A held audition button must be released and pressed again after
recording or reset. MIDI and audition share one voice: the latest accepted
note owns that voice, and an old audition release cannot stop a newer UART
note.

| LED | Meaning |
|---|---|
| 0 | Microphone capture and CIC ready. |
| 1 | Recording, including final metadata commit. |
| 2 | A usable recorded sample is available. |
| 3 | Note gate held, including sustain pedal. |
| 4 | ADSR active. |
| 5 | Sample player ready. |
| 6 | Sticky stream/pipeline error; reset clears it. |
| 7 | Sticky UART framing error; reset clears it. |
| 8 | Sticky microphone/DC clipping; reset or the next record-start clears it. |
| 15:9 | Current MIDI note number in binary. |

LED8 monitors the continuously running microphone pipeline, including time
outside recording. The default microphone shift of 12 deliberately gives
four times the Stage 12 shift-14 amplitude. That gain has not been calibrated
to the physical board. If normal input clips, first verify the recording
level and then rebuild with `MIC_PCM_SHIFT=13` or `14` as appropriate. Keep
the sample-rate equality assertion satisfied when changing microphone or
playback timing parameters.

## 8. Play from a MIDI keyboard through the PC

Connect the USB MIDI keyboard to the PC. Connect the FPGA's USB-UART link to
the PC. The Python bridge transfers complete three-byte note/control packets
at 115200 baud, 8 data bits, no parity, one stop bit. The board does not host
a USB MIDI keyboard directly in this design.

From PowerShell:

```powershell
py -m pip install -r tools/requirements.txt
py tools/midi_bridge.py list
py tools/midi_bridge.py bridge --port COM5 --midi "Exact MIDI input name"
```

Replace `COM5` and the device name with the listed values. Record a clip
first. Play notes 48 through 84; the engine is monophonic with new-note
priority. Sustain pedal CC64 is supported. Releasing the pedal releases a
note whose physical key was already released. Ctrl+C shuts down the bridge
with sustain-off/panic/note-off cleanup.

Without a keyboard, use these commands in separate invocations:

```powershell
py tools/midi_bridge.py on --port COM5 --note 69 --velocity 100
py tools/midi_bridge.py off --port COM5 --note 69
py tools/midi_bridge.py pedal --port COM5 --value 127
py tools/midi_bridge.py pedal --port COM5 --value 0
py tools/midi_bridge.py panic --port COM5
py tools/midi_bridge.py demo --port COM5
```

Only one process should hold the COM port, so stop the running bridge before
using the separate command sender. The sample is treated as root note 69:
note 69 plays at the original recorded rate, and other supported notes
transpose relative to that rate. To obtain conventional keyboard tuning,
record a source at A4 or prepare a correctly rooted sample. This version
does not estimate the recorded source's pitch or time-stretch it.

## 9. Preserve evidence and extend the project

Keep the source revision, all regression results, merged Vivado reports,
chosen generic values, and a short hardware test record together. Record
microphone level/clipping, key and sustain behavior, reset behavior,
record-stop behavior, effects, and any observed limitation. Only mark
hardware validation complete after those checks have actually been run.

For a new feature, add or extend the relevant core module and its permanent
unit bench, then update the appropriate integration bench. The board top
should mostly connect modules and board controls. Add new source/bench paths
to `vivado/sources.tcl` in dependency order and put reusable boundary variants
in its shared `regression_variants` list. Rerun the full regression before
synthesis. You do not need to keep growing one enormous top or one enormous
testbench; a new independent component should normally have its own bench.
