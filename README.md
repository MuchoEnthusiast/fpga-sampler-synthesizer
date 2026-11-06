
# FPGA Sampler Synthesizer

An FPGA-based audio sampler synthesizer implemented in VHDL
for the Digilent Nexys 4 DDR board.

## Project objectives

- Load or record audio samples
- Replay samples at different musical pitches
- Control playback using MIDI or UART
- Implement ADSR envelopes
- Implement real-time audio effects
- Support score playback (extension)

## Hardware

- Board: Digilent Nexys 4 DDR
- FPGA: Xilinx Artix-7 XC7A100T
- Clock: 100 MHz
- Language: VHDL
- Development environment: AMD Vivado

## Repository organization

- src/core: Portable synthesizer logic
- src/platform: Board-specific interfaces
- constraints: Physical pin and timing constraints
- sim: VHDL testbenches
- tools: Python conversion and verification scripts
- samples: Test audio samples
- docs: Architecture and project documentation
- vivado: Vivado project setup

## Current status

Repository initialized. Audio implementation not yet started.
