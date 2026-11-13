# Refresh generated copies from samples/. Also used as synthesis pre-hook.
set memory_script_dir [file dirname [file normalize [info script]]]
set memory_repo_root [file dirname $memory_script_dir]
source [file join $memory_script_dir sources.tcl]
set memory_project_dir [file join $memory_repo_root vivado build live_sampler]
# Deliberately restrict copies to the known generated project directories.
# In particular, sourcing this from the repository root does not copy data there.
set memory_destinations [list $memory_project_dir \
    [file join $memory_project_dir live_sampler.runs synth_1] \
    [file join $memory_project_dir live_sampler.runs impl_1] \
    [file join $memory_project_dir live_sampler.sim sim_1 behav xsim]]
foreach directory [lsort -unique $memory_destinations] {
    if {![file isdirectory $directory]} {continue}
    foreach relative $memory_files {
        set original [file normalize [file join $memory_repo_root $relative]]
        set generated [file normalize [file join $directory [file tail $relative]]]
        if {$original ne $generated} {file copy -force $original $generated}
    }
}
