# Verification record for the live sampler

## Status and evidence boundaries

The source implementation and local behavioral verification are complete. The following results were actually obtained on the supplied deliverable. No Vivado/XSim, mapped utilization, placed/routed timing, hardware audio measurement, programming, or new bitstream result is claimed.

| Check | Observed result | Evidence |
|---|---|---|
| Complete VHDL regression | **29 PASS**, GHDL 5.0.1, VHDL-2008, assertion errors/failures stop the test | [Current results and source hashes](verification/ghdl/results.json) and adjacent logs |
| MIDI bridge unit tests | **16 PASS**, no hardware/dependencies required | [Python log](verification/control/midi_bridge.log) |
| Build-script control-flow checks | **17 PASS**, independent Tcl mocks and static Python checks | [Mock results](verification/build_flow/results.json), [mock log](verification/build_flow/mock_flow_tests.log) |
| Full default-top generic synthesis front end | **PASS**; both audio RAMs recognized | [Front-end results](verification/frontend/results.json), [log](verification/frontend/top_synthesis_frontend.log) |
| Updated Stage 05 preservation | **PASS**, normalized source equality | [Preservation record](verification/adsr_reference/preservation.json), [complete diff](verification/adsr_reference/renaming.diff) |
| Top/XDC source consistency | 34 physical port bits, one pin assignment each, no missing/extra port names | Read-only source comparison using expanded Tcl pin declarations; synthesized selectors remain a Vivado check |
| Vivado, PowerShell merger and physical board | **Not run for this integration** | Follow [the local pipeline](vivado_pipeline.md) |

The authoritative complete RTL regression is the run stamped `20261112_231120_098115`, performed after the echo memory-process optimization. Its recorded manifest and every recorded source/memory hash were checked against the final files. Earlier focused logs in `control/`, `top/` and `note_arbiter/` describe the revisions recorded in those directories. They provide development evidence; the latest `ghdl/results.json` supersedes them for final RTL coverage.

## Unit coverage: 18 benches

| Bench | Principal checks |
|---|---|
| `tb_adsr_envelope` | Original pipelined envelope values, N+2 valid, minimum three-clock spacing, clamp/boundaries, pending and simultaneous events, reset cancellation. |
| `tb_audio_gain` | Signed arithmetic, velocity endpoints, gain scaling, saturation and pipeline alignment. |
| `tb_button_debouncer` | Contact bounce, held input, release, reset and stable-count boundary. |
| `tb_common` | Tick enable, synchronization, PCM widening/narrowing and signed rounding boundaries. |
| `tb_dc_blocker` | Independent integer recurrence, DC removal of both signs, exact residue extinction, clipping and N+2 valid. |
| `tb_delay_effect` | Independent feedback model, bypass history, delay wrap, saturation, negative residue and reset cancellation. |
| `tb_distortion` | Signed x2/x4 clipping, bypass and reset. |
| `tb_linear_interpolator` | Signed differences, fraction endpoints, rounding, saturation and N+2 pipeline. |
| `tb_note_event_manager` | Pitch table, range rejection, new-note priority, matching release, sustain and panic. |
| `tb_note_input_arbiter` | Coincident events, valid/invalid note priority, audition ownership and same-pitch UART takeover. |
| `tb_pdm_capture` | Clock/select phase, warmup, selected-half-cycle data, capture latency, valid pulse and reset. |
| `tb_pdm_decimator` | Independent FIR oracle, full-scale/density/sinusoidal inputs, modulo wrap, clipping and scheduled latency. |
| `tb_phase_accumulator` | Fractional steps, non-power-of-two wrap, changed/invalid length and supported boundaries. |
| `tb_pwm_generator` | Signed-to-duty conversion, carrier boundaries, input latching and reset. |
| `tb_record_controller` | Valid-only writes, start/stop priority, exact full limit, short rejection, COMMIT and reset metadata. |
| `tb_sample_player` | Synchronous RAM scheduling, nearest/linear output, ready latency, dynamic lengths and restart. |
| `tb_sample_ram` | Optional initialization, registered read and write behavior. |
| `tb_uart_control` | UART frames/errors and complete note/pedal/panic decoding. |

## Integration coverage: six benches

| Bench | Principal checks |
|---|---|
| `tb_effects_chain` | Distortion/echo numeric and valid alignment, bypass and reset. |
| `tb_live_sampler` | Actual recorder/RAM/player/preserved-ADSR/gain/effects chain driven by known PCM; full and manual recordings, invalid short clip, half/double pitch, independent fixed-point oracle, sustain, panic, echo tails, volume/control capture and N+9 output. |
| `tb_microphone` | Real 100 MHz / 2 MHz / 16 kHz acquisition path with intended-bit/FIR/DC reference model, exact cadence, reset, silence and clipping. |
| `tb_record_playback` | Last-write commit, runtime lengths, looping, short recordings, recovery and pitch. |
| `tb_sampler_core` | Retained preloaded-sample regression with the updated ADSR timing and complete effects chain. |
| `tb_top_nexys4ddr` | Actual microphone acquisition, board buttons, UART packets, recording and playback, velocity/octaves, sustain, panic, short/invalid re-recording, output PWM, framing diagnostics and same-pitch ownership takeover. |

The microphone/top benches retain the actual system/microphone/audio rate relationship. Warmup, clip length, and selected UART/button delays are accelerated where documented by each bench. A digital microphone timing model drives a valid bit 60 ns after falling M_CLK and releases it 5 ns after rising M_CLK. This deliberately tests the selected half-cycle; it is not a measured board timing result.

The six integration benches do not all include the microphone. `tb_live_sampler` accepts reference PCM directly, while `tb_microphone` tests acquisition and `tb_top_nexys4ddr` tests their complete connection. This separation makes failures attributable to a specific boundary.

## Five additional generic cases

| Regression case | Base bench | Overrides |
|---|---|---|
| `tb_delay_effect_depth1` | `tb_delay_effect` | `DELAY_SAMPLES=1` |
| `tb_delay_effect_depth4` | `tb_delay_effect` | `DELAY_SAMPLES=4` |
| `tb_record_controller_full_depth` | `tb_record_controller` | `MAX_SAMPLES_G=16` |
| `tb_pdm_decimator_r1` | `tb_pdm_decimator` | `DECIMATION=1, BASE_SHIFT=3` |
| `tb_pdm_decimator_r5` | `tb_pdm_decimator` | `DECIMATION=5, BASE_SHIFT=3` |

The recorder's full-depth variant uses a 16-address test RAM to exercise the otherwise easily missed full-capacity length bit. Playback/phase tests also exercise the production 16,000-sample loop arithmetic. The default full-top synthesis uses the actual 16,384-address RAM and 16,000-sample recording limit. No claim of an exhaustive one-second analog recording simulation is made.

## Generic synthesis and memory inference

The exact production-default `top_nexys4ddr` elaborates through GHDL's `--synth --std=08` front end. The diagnostic reports:

```text
found RAM "ram", width: 8 bits, depth: 16384
found RAM "delay_ram", width: 16 bits, depth: 4096
```

GHDL warns that it does not implement Vivado-specific `ASYNC_REG`, `SHREG_EXTRACT`, and `ram_style` attributes. These warnings were retained. The output is a generic VHDL netlist, not a placed Artix-7 netlist. No LUT/FF/BRAM/DSP count or maximum clock frequency is inferred from its text size.

An earlier generic synthesis check did not recognize the echo array as RAM. The echo access was moved into a separate reset-free clocked memory process, while reset gates accesses and invalidates the history metadata. Focused echo tests and the full regression passed afterwards. [The focused evidence](verification/echo_ram_inference/results.json) and its adjacent logs record that inference-portability optimization. This does not establish that the earlier code failed Vivado inference.

## Exact ADSR preservation and historical results

The uploaded `05_ADSR_envelope.vhd` SHA-256 is `86715c97c896d60e8e5a921ca04a8f62f543572aaf3b6b69e8521f14f7b0fda0`. The production file is `b94d242f6138faaf9ec295fd02561ef7ea90d06bd3d7a2ccf2748a09fc45aa51`. Applying the documented entity/header/newline normalizations makes their complete contents identical. There is one production ADSR implementation and all playback reaches it through `sampler_core`.

The uploaded Stage 05 pipelined report has setup WNS +0.205 ns and hold WHS +0.035 ns. The corrected Stage 05 board report has +0.521/+0.167 ns, and the uploaded Stage 07 report has +0.184/+0.152 ns. These establish historical timing evidence for their corresponding experiments only. See [the preservation record](adsr_preservation.md) for links. New routed timing must be collected for this complete live design.

## Local acceptance gates

Run the complete XSim regression and require all 29 cases to produce a fresh PASS. Synthesize and route the correct part/top with current sources. Review setup, hold, pulse width, constraint coverage, first-stage-only exceptions, CDC, DRC, routing and resource inference. Merge all 14 exported reports using the provided PowerShell tool. Generate and program the bitstream only after that review.

Then test microphone readiness, a full recording, an early stop, audition, a new recording after playback, MIDI notes/velocity/sustain, panic, all effects and reset. Record clipping, audible artifacts, measured resources/timing, actual generic settings, and the exact Git revision. Only then mark the new integration hardware-validated.

The detailed commands, expected results and hardware controls are in [vivado_pipeline.md](vivado_pipeline.md). The unit/integration benches remain permanent regression assets when future stages add features.
