# Canonical explicit compile order shared by Vivado and GHDL.
set rtl_files {
    src/core/common/audio_pkg.vhd
    src/core/common/sample_tick_generator.vhd
    src/core/common/input_synchronizer.vhd
    src/core/common/button_debouncer.vhd
    src/core/interfaces/uart_rx.vhd
    src/core/interfaces/pdm_capture.vhd
    src/core/control/note_command_decoder.vhd
    src/core/control/note_event_manager.vhd
    src/core/control/note_input_arbiter.vhd
    src/core/memory/sample_ram.vhd
    src/core/memory/record_controller.vhd
    src/core/audio/pdm_decimator.vhd
    src/core/audio/dc_blocker.vhd
    src/core/audio/phase_accumulator.vhd
    src/core/audio/linear_interpolator.vhd
    src/core/audio/sample_player.vhd
    src/core/audio/adsr_envelope.vhd
    src/core/audio/audio_gain.vhd
    src/core/effects/distortion.vhd
    src/core/effects/delay_effect.vhd
    src/core/interfaces/pwm_generator.vhd
    src/core/audio/sampler_core.vhd
    src/platform/nexys4ddr/top_nexys4ddr.vhd
}
set tb_files {
    sim/unit/tb_adsr_envelope.vhd
    sim/unit/tb_audio_gain.vhd
    sim/unit/tb_button_debouncer.vhd
    sim/unit/tb_common.vhd
    sim/unit/tb_dc_blocker.vhd
    sim/unit/tb_delay_effect.vhd
    sim/unit/tb_distortion.vhd
    sim/unit/tb_linear_interpolator.vhd
    sim/unit/tb_note_event_manager.vhd
    sim/unit/tb_note_input_arbiter.vhd
    sim/unit/tb_pdm_capture.vhd
    sim/unit/tb_pdm_decimator.vhd
    sim/unit/tb_phase_accumulator.vhd
    sim/unit/tb_pwm_generator.vhd
    sim/unit/tb_record_controller.vhd
    sim/unit/tb_sample_player.vhd
    sim/unit/tb_sample_ram.vhd
    sim/unit/tb_uart_control.vhd
    sim/integration/tb_effects_chain.vhd
    sim/integration/tb_live_sampler.vhd
    sim/integration/tb_microphone.vhd
    sim/integration/tb_record_playback.vhd
    sim/integration/tb_sampler_core.vhd
    sim/integration/tb_top_nexys4ddr.vhd
}
set memory_files {
    samples/sample_a4.mem
    samples/test_core.mem
}

# case|bench|GENERIC=VALUE,GENERIC2=VALUE. Keep these entries whitespace-free;
# both regression runners parse this same static list.
set regression_variants {
    tb_delay_effect_depth1|tb_delay_effect|DELAY_SAMPLES=1
    tb_delay_effect_depth4|tb_delay_effect|DELAY_SAMPLES=4
    tb_record_controller_full_depth|tb_record_controller|MAX_SAMPLES_G=16
    tb_pdm_decimator_r1|tb_pdm_decimator|DECIMATION=1,BASE_SHIFT=3
    tb_pdm_decimator_r5|tb_pdm_decimator|DECIMATION=5,BASE_SHIFT=3
}
