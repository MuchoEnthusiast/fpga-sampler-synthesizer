# Stage 01–17 migration record

The source snapshot is the supplied `debug (2).zip`, SHA-256 `5340e0a644e895fb28c99ad660392150337a1806220134823e7d57f45b1b7129`. The snapshot was inspected as experimental evidence; the production source manifest never reads from it. No new Stage ID has been assigned and the user's flat ignored `debug/` convention remains unchanged.

| Stage | Production destination and decision |
|---|---|
| 01 audio tone/PWM | Reusable signed-PCM PWM in `interfaces/pwm_generator.vhd`; physical 0/Z wiring stays in the board top. The tone experiment is not a second production audio path. |
| 02 sample playback/RAM | `memory/sample_ram.vhd`, optional sample initialization, `tools/make_sample.py`, permanent RAM and playback benches. |
| 03 pitch shift | `audio/phase_accumulator.vhd`; runtime length and integer-field wrap optimization added. |
| 04 interpolation | `audio/linear_interpolator.vhd` and the scheduled/prefetched `audio/sample_player.vhd`; nearest/linear modes retained. |
| 05 ADSR | The actual updated pipelined upload is preserved in `audio/adsr_envelope.vhd`. Only entity/header/newlines differ. Original RTL, normalized diff and historical timing are archived as evidence. |
| 06 UART control | Reusable `interfaces/uart_rx.vhd` and `control/note_command_decoder.vhd`; explicit CC64 and panic packets added. |
| 07 integration | `control/note_event_manager.vhd`, `audio/audio_gain.vhd` and portable `audio/sampler_core.vhd`; legacy ADSR copies are replaced by the preserved Stage 05 instance. |
| 08 distortion | `effects/distortion.vhd`, permanent saturation/bypass tests and effects-chain integration. |
| 09 echo | `effects/delay_effect.vhd`; original feedback/bypass/rounding semantics retained. Separate reset-free RAM process enables generic RAM inference. |
| 10 echo verification | Boundary/reset/bypass checks are represented in permanent echo/effects tests, including delay-depth 1 and 4 variants. No duplicate runtime module is required. |
| 11 microphone capture | Capture RTL retained in `interfaces/pdm_capture.vhd`. Activity-only demonstration logic is superseded by actual PCM/recording readiness and clipping diagnostics. |
| 12 PDM-to-PCM | `audio/pdm_decimator.vhd` preserves CIC behavior with an explicit register schedule. New `audio/dc_blocker.vhd` removes microphone/DC bias before recording. |
| 13 recorder | `memory/record_controller.vhd` provides exact dynamic length, minimum-length rejection, last-write COMMIT and reset-safe metadata. Production uses real microphone PCM instead of the fallback generator. |
| 14 record/play demo | Runtime recorded length is integrated into the reusable player and phase logic. Separate old demo gain/player/RAM copies are consolidated. |
| 15 release workflow | Production Tcl, report collection/merge, regression evidence and complete source listing replace per-experiment release scripts. Historical experiment release status does not establish new production validation. |
| 16 combined integration | The supplied `16_INTEGRATION_pdm_pcm.vhd` is zero bytes; it was not treated as an implemented microphone block. The completed production top connects the actual capture/CIC/DC/record/play paths and preserved Stage 05 pipeline. Debounce and effects remain reusable components. |
| 17 USB MIDI bridge | `tools/midi_bridge.py` and its Python tests, extended to sustain/panic. Added a tested hardware audition/UART owner arbiter for coincident-event correctness. |

Experimental tops, self-contained old copies and project-specific generated outputs are not promoted into `src/`. Their reusable functions are represented by the single components listed above. All retained production functions have permanent unit or integration coverage. This migration does not retroactively mark an experiment as hardware-validated.

## Future stages

Use the next globally unallocated Stage ID only after consulting the repository's experiment register. Keep the experiment flat under `debug/`, then promote validated logic and tests into the established folders. Usually a feature needs a component, its unit bench, a small integration change and a regression-manifest update. Only new board signals or controls require top-level port/XDC changes. Do not duplicate the ADSR or grow a second parallel implementation of a production block.
