# Export completed runs only. Does not launch, reset or generate a bitstream.
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_dir]
set project_dir [file join $repo_root vivado build live_sampler]
if {[llength [get_projects -quiet]] == 0} {
    open_project [file join $project_dir live_sampler.xpr]
}
if {[file normalize [get_property DIRECTORY [current_project]]] ne $project_dir} {
    error "Open the live sampler project before exporting its reports."
}
foreach run_name {synth_1 impl_1} {
    set run [get_runs $run_name]
    set status [get_property STATUS $run]
    if {[get_property NEEDS_REFRESH $run] || ![string match "*Complete*" $status]} {
        error "$run_name must be complete and current: $status"
    }
    if {$run_name eq "impl_1" && ![string match "route_design Complete*" $status] &&
        ![string match "write_bitstream Complete*" $status]} {
        error "Implementation must finish routing before report export: $status"
    }
}
set report_dir [file join $project_dir reports]
file mkdir $report_dir
set handle [open [file join $report_dir provenance.txt] w]
puts $handle "Export time UTC: [clock format [clock seconds] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]"
puts $handle "Vivado: [version -short]"
puts $handle "Project: $project_dir"
puts $handle "Part: [get_property PART [current_project]]"
puts $handle "Top: [get_property TOP [get_filesets sources_1]]"
foreach run_name {synth_1 impl_1} {
    puts $handle "$run_name: [get_property STATUS [get_runs $run_name]]"
    puts $handle "$run_name needs refresh: [get_property NEEDS_REFRESH [get_runs $run_name]]"
}
puts $handle "\nRegistered source/data/constraint paths:"
foreach path [lsort [get_files]] {
    puts $handle $path
    if {[file isfile $path]} {
        puts $handle "  bytes: [file size $path]"
        puts $handle "  modified UTC: [clock format [file mtime $path] -gmt 1 -format {%Y-%m-%dT%H:%M:%SZ}]"
    }
}
puts $handle "\nSource manifest at export:"
set manifest_handle [open [file join $script_dir sources.tcl] r]
puts $handle [read $manifest_handle]
close $manifest_handle
close $handle
# Reports below use stored runs; save any interactive design edits beforehand.
if {[llength [get_designs -quiet]] != 0} {close_design}
foreach run_name {synth_1 impl_1} prefix {synth impl} {
    open_run $run_name
    report_utilization -hierarchical -file [file join $report_dir ${prefix}_utilization.rpt]
    report_timing_summary -delay_type min_max -check_timing_verbose \
        -report_unconstrained -max_paths 20 -file [file join $report_dir ${prefix}_timing.rpt]
    report_drc -file [file join $report_dir ${prefix}_drc.rpt]
    file copy -force [file join [get_property DIRECTORY [get_runs $run_name]] runme.log] \
        [file join $report_dir ${prefix}_runme.log]
    if {$run_name eq "impl_1"} {
        report_route_status -file [file join $report_dir impl_route.rpt]
        report_io -file [file join $report_dir impl_io.rpt]
        report_clocks -file [file join $report_dir impl_clocks.rpt]
        report_cdc -details -file [file join $report_dir impl_cdc.rpt]
        report_methodology -file [file join $report_dir impl_methodology.rpt]
    }
    close_design
}
puts "Reports exported: $report_dir"
puts "Review timing, DRC, routing and constraints before generating the bitstream."
