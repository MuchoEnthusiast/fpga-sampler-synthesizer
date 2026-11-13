# Microphone capture and recording front end

## Reused and completed components

`src/core/interfaces/pdm_capture.vhd` preserves the Stage 11 capture RTL, with only its entity name and production comments changed. It drives M_CLK as an ordinary registered output; all internal registers remain in the 100 MHz system-clock domain. The two receiving registers retain `ASYNC_REG` and `SHREG_EXTRACT` attributes. The board wrapper must constrain the asynchronous path only into `pdm_meta` while retaining timing between the two stages.

The supplied Stage 16 `pdm_pcm` source is empty. The completed acquisition path therefore uses the actual Stage 11 capture and Stage 12 CIC behavior, followed by a new explicit DC-removal component.

The Nexys 4 DDR reference manual specifies microphone clocks between 1 and 3.3 MHz and rising-edge data availability with L/R select low. The preserved capture samples the pin at the system-clock edge that launches rising M_CLK and publishes that captured value after its two receiving stages. The microphone model in the benches drives a bit 60 ns after falling M_CLK and releases the pin 5 ns after rising M_CLK, so accidentally using data from the inactive half-cycle fails the checks. This model is a digital timing assumption, not a board measurement.

Primary source: [Digilent Nexys4 DDR Reference Manual, section 15.2](https://digilent.com/reference/_media/nexys4-ddr:nexys4ddr_rm.pdf).

## Scheduling and numerical behavior

| Component | Contract |
|---|---|
| `pdm_capture` | Default half-period 25 clocks: 2 MHz M_CLK; default startup wait 5,000,000 clocks: 50 ms. One captured bit per complete M_CLK period. |
| `pdm_decimator` | Three-integrator/three-comb CIC; bipolar input +/-1; modulo 2^32 internal arithmetic; one candidate per 125 accepted bits; first two candidates discarded. |
| CIC schedule | Last input bit at N, third integrator at N+2, comb stages at N+3/N+4/N+5, rounded PCM and valid at N+6. Input spacing must be at least three clocks; hardware supplies 50. |
| CIC scaling | `G_SHIFT=14` preserves Stage 12's approximately +/-119 full-scale calibration. The top can select `G_SHIFT=12` for 4x microphone gain. Saturation is explicitly flagged. |
| CIC readiness | `ready` becomes high with the first published PCM sample and remains high until reset. |
| `dc_blocker` | Q8 signed state; approximate pole 255/256 for default `LEAK_SHIFT=8`, around 10 Hz cutoff at 16 kHz. Accepted sample at N produces output after N+2; input spacing at least three clocks. |
| DC residue | Leakage magnitude rounds away from zero, so positive and negative internal residue both decay exactly to zero. State retains headroom; only the public signed-8 output saturates. |
| Complete path | Last selected microphone rising edge at E produces filtered PCM after E+12, including inter-module valid transfer. Normal output interval is exactly 6,250 system clocks, or 62.5 us. |
| `button_debouncer` | Takes an already synchronized bit. Requires the configured number of consecutive differing samples to change its output level; emits one pulse on a debounced rising transition. Default 500,000 clocks is 5 ms. |

Stage 12 previously placed three integrator additions, three comb subtractions and output quantization on the same enabled clock edge. The promoted version registers each scheduled stage, preserving its CIC transfer function while removing that long arithmetic chain. A 2 MHz bitstream leaves ample system-clock cycles for this schedule. The filter uses additions, subtractions and constant shifts; no DSP multipliers or sample RAM are required by these front-end modules.

DC removal is an intentional addition before recording. Its equation is

`y[n] = x[n] - x[n-1] + y[n-1] - leak(y[n-1])`.

The fractional-state leakage is `sign(y) * ceil(abs(y)/256)`. The output rounds to nearest with ties away from zero, then saturates to PCM8. Filter history must keep advancing between recordings; recording control need not reset it.

This is a compact 8-bit voice-sampling front end. A third-order CIC has passband droop and finite alias rejection; the tests establish its specified arithmetic, rate and scheduling, not studio-quality analog response or measured microphone sensitivity.

## Verification completed

GHDL 5.0.1, VHDL-2008, `--assert-level=error`:

- `tb_pdm_capture`: PASS. Clock rate, low-channel selection, startup masking, two-cycle capture publication, one-cycle valid, reset cancellation, inactive-half-cycle rejection.
- `tb_pdm_decimator`: PASS. Independent 373-tap FIR convolution oracle for the default CIC, positive/negative full scale, 50/75/25 percent density, generated PDM sinusoid, integrator wrap, saturation at 4x gain, exact N+6 scheduling and reset cancellation.
- The same decimator bench additionally passed `DECIMATION=1, BASE_SHIFT=3` and `DECIMATION=5, BASE_SHIFT=3`, including overlapping scheduled comb jobs.
- `tb_dc_blocker`: PASS. Both signs of DC, exact residue extinction, signed boundaries, saturation, independent integer recurrence, 1 kHz sinusoid on a DC offset, N+2 scheduling and reset cancellation.
- `tb_button_debouncer`: PASS. Contact bounce, prolonged hold, release, reset and the one-cycle stable-count boundary case.
- `tb_microphone`: PASS at 7,379,336 ns. Full capture/CIC/DC path at real 100 MHz/2 MHz/16 kHz rates, independent intended-bit/FIR/DC oracle, clipping status, exact output cadence, reset and silence. Only startup waiting is accelerated.

The GHDL generic synthesis front end also accepted all four RTL components. Its logs are supplemental syntax/synthesizability evidence only. Vivado resource inference, actual routed timing, CDC reports and physical microphone operation remain pending.
