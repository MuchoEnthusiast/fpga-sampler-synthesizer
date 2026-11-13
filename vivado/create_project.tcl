set script_dir [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_dir]
source [file join $script_dir sources.tcl]
set project_dir [file join $repo_root vivado build live_sampler]
set project_file [file join $project_dir live_sampler.xpr]
if {[file exists $project_file]} {
    error "Project already exists. Open it instead: $project_file"
}
if {[llength [get_projects -quiet]] != 0} {
    error "Close the current project before creating the live sampler project."
}
foreach relative [concat $rtl_files $tb_files $memory_files \
                  {constraints/nexys4ddr.xdc}] {
    if {![file isfile [file join $repo_root $relative]]} {
        error "Missing source: $relative"
    }
}
create_project live_sampler $project_dir -part xc7a100tcsg324-1
set_property target_language VHDL [current_project]
set_property target_simulator XSim [current_project]
foreach fileset {sources_1 sim_1} files [list $rtl_files $tb_files] {
    foreach relative $files {
        set path [file join $repo_root $relative]
        add_files -norecurse -fileset $fileset $path
        set_property FILE_TYPE {VHDL 2008} [get_files $path]
    }
}
foreach relative $memory_files {
    add_files -norecurse -fileset sources_1 [file join $repo_root $relative]
}
add_files -norecurse -fileset constrs_1 \
    [file join $repo_root constraints nexys4ddr.xdc]
set_property top top_nexys4ddr [get_filesets sources_1]
set_property top tb_top_nexys4ddr [get_filesets sim_1]
set_property SOURCE_SET sources_1 [get_filesets sim_1]
set_property STEPS.SYNTH_DESIGN.TCL.PRE \
    [file join $script_dir stage_memory.tcl] [get_runs synth_1]
# Pre-stage data for interactive simulation; use -noclean_dir when launching.
foreach directory [list $project_dir \
        [get_property DIRECTORY [get_runs synth_1]] \
        [get_property DIRECTORY [get_runs impl_1]] \
        [file join $project_dir live_sampler.sim sim_1 behav xsim]] {
    file mkdir $directory
    foreach relative $memory_files {
        file copy -force [file join $repo_root $relative] \
            [file join $directory [file tail $relative]]
    }
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "Created: $project_file"
