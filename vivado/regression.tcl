# Run with the live sampler project open, or from Vivado batch mode.
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file dirname $script_dir]
source [file join $script_dir sources.tcl]
set project_dir [file join $repo_root vivado build live_sampler]
if {[llength [get_projects -quiet]] == 0} {
    open_project [file join $project_dir live_sampler.xpr]
}
if {[file normalize [get_property DIRECTORY [current_project]]] ne $project_dir} {
    error "Open the live sampler project before running this regression."
}
set result_dir [file join $project_dir regression \
    "[clock format [clock seconds] -format %Y%m%d_%H%M%S]_[clock clicks]"]
file mkdir $result_dir
set sim_dir [file join $project_dir live_sampler.sim sim_1 behav xsim]
set old_top [get_property top [get_filesets sim_1]]
set old_generics [get_property generic [get_filesets sim_1]]
set old_custom [get_property xsim.simulate.custom_tcl [get_filesets sim_1]]
set old_cwd [pwd]
set regression_cases {}
set bench_names {}
foreach relative $tb_files {
    set bench [file rootname [file tail $relative]]
    lappend regression_cases [list $bench $bench {}]
    lappend bench_names $bench
}
set case_names $bench_names
foreach variant $regression_variants {
    set fields [split $variant |]
    if {[llength $fields] != 3} {error "Invalid regression variant: $variant"}
    lassign $fields case_name bench values
    if {![regexp {^[A-Za-z][A-Za-z0-9_]*$} $case_name] ||
        [lsearch -exact $bench_names $bench] < 0 ||
        [lsearch -exact $case_names $case_name] >= 0} {
        error "Unknown bench or duplicate/invalid case: $variant"
    }
    set generics [split $values ,]
    foreach value $generics {
        if {![regexp {^[A-Za-z][A-Za-z0-9_]*=[-+A-Za-z0-9_.]+$} $value]} {
            error "Invalid generic assignment: $variant"
        }
    }
    lappend regression_cases [list $case_name $bench $generics]
    lappend case_names $case_name
}
set failure [catch {
    set_property xsim.simulate.custom_tcl [file join $script_dir run_all.tcl] \
        [get_filesets sim_1]
    foreach regression_case $regression_cases {
        lassign $regression_case case_name bench generics
        set bench_dir [file join $result_dir $case_name]
        file mkdir $bench_dir
        set_property top $bench [get_filesets sim_1]
        # Each bench starts with exactly its own overrides. User overrides are
        # restored after regression, including when a case fails.
        set_property generic $generics [get_filesets sim_1]
        set handle [open [file join $bench_dir case.txt] w]
        puts $handle "Case: $case_name"
        puts $handle "Bench: $bench"
        puts $handle "Generics: $generics"
        puts $handle "Vivado: [version -short]"
        close $handle
        update_compile_order -fileset sim_1
        launch_simulation -simset sim_1 -mode behavioral -scripts_only -absolute_path
        # Generate first, then stage data BEFORE elaboration opens VHDL files.
        foreach memory $memory_files {
            file copy -force [file join $repo_root $memory] \
                [file join $sim_dir [file tail $memory]]
        }
        # Preserve any logs retained by the tool, excluding them from this test.
        foreach log [glob -nocomplain -directory $sim_dir *.log] {
            file rename -force $log [file join $bench_dir "before_[file tail $log]"]
        }
        cd $sim_dir
        foreach step {compile elaborate simulate} {
            if {$tcl_platform(platform) eq "windows"} {
                set command [list cmd.exe /d /c "${step}.bat"]
            } else {
                set command [list bash "./${step}.sh"]
            }
            set bad [catch {exec {*}$command 2>@1} transcript]
            set handle [open [file join $bench_dir "${step}.console.log"] w]
            puts $handle $transcript
            close $handle
            set diagnostics $transcript
            foreach log [glob -nocomplain -directory $sim_dir *.log] {
                file copy -force $log [file join $bench_dir [file tail $log]]
                set handle [open $log r]
                append diagnostics "\n" [read $handle]
                close $handle
            }
            if {$bad} {error "$case_name $step failed. See $bench_dir"}
            if {[regexp -nocase {(^|\n)[ \t]*(ERROR|FATAL|Failure)[ \t]*:|assertion[ \t]+(error|failure)} $diagnostics]} {
                error "$case_name $step reported an error. See $bench_dir"
            }
            if {$step eq "simulate"} {
                set pass_pattern [format {PASS:\s+%s(?:\s|$)} $bench]
                if {![regexp $pass_pattern $diagnostics]} {
                    error "$case_name did not reach PASS: $bench. See $bench_dir"
                }
            }
        }
        cd $old_cwd
        puts "PASS: $case_name"
    }
} problem]
cd $old_cwd
set_property top $old_top [get_filesets sim_1]
set_property generic $old_generics [get_filesets sim_1]
set_property xsim.simulate.custom_tcl $old_custom [get_filesets sim_1]
update_compile_order -fileset sim_1
if {$failure} {error $problem}
puts "PASS: all [llength $regression_cases] Vivado regression cases ([llength $tb_files] benches). Logs: $result_dir"
