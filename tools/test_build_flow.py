#!/usr/bin/env python3
"""Mock checks for build-script control flow; these do not execute Vivado.

Requires Python, tclsh and bash. All generated projects/reports live in an
isolated temporary repository. Run from any directory with
    python tools/test_build_flow.py
"""
from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
set mock_root [file normalize [lindex $argv 0]]
set scenario [lindex $argv 1]
set script_name [lindex $argv 2]
set mock_project [file join $mock_root vivado build live_sampler]
set mock_sim [file join $mock_project live_sampler.sim sim_1 behav xsim]
set mock_open 1
set mock_paths {}
set mock_launches {}
set mock_designs {}
set mock_properties [dict create \
    project [dict create DIRECTORY $mock_project PART xc7a100tcsg324-1] \
    sources_1 [dict create TOP top_nexys4ddr] \
    sim_1 [dict create TOP user_original_top GENERIC {USER_VALUE=19 FLAG=1} \
        XSIM.SIMULATE.CUSTOM_TCL user_original_script.tcl] \
    synth_1 [dict create STATUS {synth_design Complete!} NEEDS_REFRESH 0 \
        DIRECTORY [file join $mock_project live_sampler.runs synth_1]] \
    impl_1 [dict create STATUS {route_design Complete!} NEEDS_REFRESH 0 \
        DIRECTORY [file join $mock_project live_sampler.runs impl_1]]]
proc check {condition message} {
    if {![uplevel 1 [list expr $condition]]} {error "MOCK ASSERT: $message"}
}
proc put_file {path text} {
    file mkdir [file dirname $path]
    set handle [open $path w]
    puts $handle $text
    close $handle
}
proc get_projects {args} {if {$::mock_open} {return project}; return {}}
proc current_project {} {return project}
proc get_filesets {name} {return $name}
proc get_runs {name} {return $name}
proc get_files {args} {
    if {[llength $args] == 0} {return $::mock_paths}
    return [lindex $args end]
}
proc get_property {name object} {
    return [dict get $::mock_properties $object [string toupper $name]]
}
proc set_property {name value object} {
    dict set ::mock_properties $object [string toupper $name] $value
}
proc version {args} {return MOCK_ONLY_NO_VIVADO}
proc update_compile_order {args} {
    check {[llength $args] == 2 && [lindex $args 0] eq "-fileset"} "compile-order options"
}
proc open_project {path} {
    check {$path eq [file join $::mock_project live_sampler.xpr]} "wrong project path"
    set ::mock_open 1
}
proc create_project {name directory args} {
    check {$name eq "live_sampler" && $directory eq $::mock_project} "project isolation"
    check {$args eq {-part xc7a100tcsg324-1}} "part argument"
    set ::mock_open 1
    put_file [file join $directory live_sampler.xpr] MOCK_PROJECT
}
proc add_files {args} {
    check {[lrange $args 0 1] eq {-norecurse -fileset}} "files must reference repository"
    set path [lindex $args end]
    check {[file isfile $path]} "missing registered input"
    lappend ::mock_paths $path
}
proc launch_simulation {args} {
    check {$args eq {-simset sim_1 -mode behavioral -scripts_only -absolute_path}} "simulation options"
    set top [get_property TOP sim_1]
    set generic [get_property GENERIC sim_1]
    lappend ::mock_launches [list $top $generic]
    file mkdir $::mock_sim
    # A stale PASS must never be accepted as evidence from this invocation.
    put_file [file join $::mock_sim stale.log] "PASS: $top"
    put_file [file join $::mock_sim compile.sh] {printf 'MOCK compile\n' > xvhdl.log}
    put_file [file join $::mock_sim elaborate.sh] {
set -e
test -s sample_a4.mem
test -s test_core.mem
printf 'MOCK elaborate: both memory files present\n' > elaborate.log
}
    set body "printf 'PASS: $top\\n' > simulate.log"
    switch -- $::scenario {
        no_pass {set body {printf 'MOCK completed without pass\n' > simulate.log}}
        wrong_pass {set body "printf 'PASS: ${top}_wrong\\n' > simulate.log"}
        nonzero {set body {printf 'MOCK process failure\n' > simulate.log; exit 3}}
        diagnostic {set body {printf 'ERROR: deliberately injected\n' > simulate.log}}
    }
    put_file [file join $::mock_sim simulate.sh] $body
}
proc get_designs {args} {return $::mock_designs}
proc close_design {} {set ::mock_designs {}}
proc open_run {name} {set ::mock_designs $name}
proc mock_report {args} {
    set index [lsearch -exact $args -file]
    check {$index >= 0} "missing report output"
    put_file [lindex $args [expr {$index+1}]] {MOCK report: not a tool result}
}
foreach command {report_utilization report_timing_summary report_drc report_route_status \
        report_io report_clocks report_cdc report_methodology} {
    interp alias {} $command {} mock_report
}
set previous_cwd [file join $mock_root unrelated_cwd]
file mkdir $previous_cwd
cd $previous_cwd
if {$script_name eq "create_project.tcl"} {set mock_open 0}
if {$scenario eq "already_exists"} {
    put_file [file join $mock_project live_sampler.xpr] EXISTING_PROJECT
}
if {$scenario eq "stale_synth"} {dict set mock_properties synth_1 NEEDS_REFRESH 1}
if {$scenario eq "unrouted"} {dict set mock_properties impl_1 STATUS {place_design Complete!}}
if {$scenario eq "wrong_project"} {dict set mock_properties project DIRECTORY /other/project}
if {$scenario eq "closed_project"} {set mock_open 0}
foreach run {synth_1 impl_1} {
    put_file [file join [get_property DIRECTORY $run] runme.log] MOCK_RUN_LOG
}
source [file join $mock_root vivado sources.tcl]
set expected_cases {}
foreach relative $tb_files {
    lappend expected_cases [list [file rootname [file tail $relative]] {}]
}
foreach entry $regression_variants {
    lassign [split $entry |] name bench values
    lappend expected_cases [list $bench [split $values ,]]
}
foreach relative [concat $rtl_files $tb_files $memory_files {constraints/nexys4ddr.xdc}] {
    lappend mock_paths [file join $mock_root $relative]
}
if {$script_name eq "create_project.tcl"} {set mock_paths {}}
set caught [catch {source [file join $mock_root vivado $script_name]} message options]
if {$script_name eq "regression.tcl"} {
    check {[pwd] eq $previous_cwd} "regression did not restore working directory"
    check {[get_property TOP sim_1] eq "user_original_top"} "top not restored"
    check {[get_property GENERIC sim_1] eq {USER_VALUE=19 FLAG=1}} "generics not restored"
    check {[get_property XSIM.SIMULATE.CUSTOM_TCL sim_1] eq "user_original_script.tcl"} "custom Tcl not restored"
    if {$scenario eq "success" || $scenario eq "closed_project"} {
        check {!$caught} "regression unexpectedly failed: $message"
        check {$mock_launches eq $expected_cases} "bench order or generic values differ from manifest"
        set archived [glob -nocomplain [file join $mock_project regression * * before_stale.log]]
        check {[llength $archived] == [llength $expected_cases]} "stale logs not archived per case"
    } else {
        check {$caught} "negative regression test did not fail"
        if {$scenario ne "wrong_project"} {
            check {[llength $mock_launches] == 1} "regression continued after failure"
        }
    }
} elseif {$script_name eq "create_project.tcl"} {
    if {$scenario eq "already_exists"} {
        check {$caught && [string match {Project already exists*} $message]} "existing project was not protected"
    } else {
        check {!$caught} "project creation failed: $message"
        check {[get_property TOP sources_1] eq "top_nexys4ddr"} "synthesis top"
        check {[get_property TOP sim_1] eq "tb_top_nexys4ddr"} "simulation top"
        check {[llength $mock_paths] == [llength [concat $rtl_files $tb_files $memory_files]]+1} "source count"
        foreach relative [concat $rtl_files $tb_files] {
            check {[get_property FILE_TYPE [file join $mock_root $relative]] eq "VHDL 2008"} "VHDL version"
        }
    }
} elseif {$script_name eq "export_reports.tcl"} {
    set report_path [file join $mock_project reports]
    if {$scenario eq "success" || $scenario eq "closed_project"} {
        check {!$caught} "export failed: $message"
        check {[llength [glob -directory $report_path *]] == 14} "report count"
        set handle [open [file join $report_path provenance.txt] r]
        set content [read $handle]
        close $handle
        foreach expected {"Export time UTC:" "Part: xc7a100tcsg324-1" "Top: top_nexys4ddr" \
                "synth_1: synth_design Complete!" "impl_1: route_design Complete!" \
                "src/core/audio/adsr_envelope.vhd" "Source manifest at export:"} {
            check {[string first $expected $content] >= 0} "incomplete source provenance"
        }
    } else {
        check {$caught} "invalid run was accepted"
        check {![file exists $report_path]} "reports created before run gate"
    }
}
puts "MOCK PASS: $script_name / $scenario"
'''


@unittest.skipUnless(shutil.which("tclsh") and shutil.which("bash"), "requires tclsh and bash")
class BuildFlowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fpga_flow_mock_")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "repo with spaces"
        shutil.copytree(ROOT / "vivado", self.repo / "vivado",
                        ignore=shutil.ignore_patterns("build"))
        manifest = (self.repo / "vivado/sources.tcl").read_text()
        for name in ("rtl_files", "tb_files", "memory_files"):
            values = re.search(r"set\s+" + name + r"\s+\{([^}]*)\}", manifest, re.S)
            for relative in values.group(1).split():
                path = self.repo / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("00\n" if path.suffix == ".mem" else "-- MOCK input\n")
        (self.repo / "constraints").mkdir()
        (self.repo / "constraints/nexys4ddr.xdc").write_text("# MOCK constraints\n")
        self.harness = Path(self.temporary.name) / "harness.tcl"
        self.harness.write_text(HARNESS)

    def run_case(self, script, scenario="success"):
        result = subprocess.run(["tclsh", str(self.harness), str(self.repo), scenario, script],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"MOCK PASS: {script} / {scenario}", result.stdout)

    def test_tcl_syntax_complete(self):
        for script in (self.repo / "vivado").glob("*.tcl"):
            check = 'set h [open [lindex $argv 0]]; set s [read $h]; close $h\n'
            check += 'if {![info complete $s]} {error "Incomplete Tcl syntax"}\n'
            self.harness.write_text(check)
            result = subprocess.run(["tclsh", str(self.harness), str(script)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_project_creation(self): self.run_case("create_project.tcl")
    def test_existing_project_protected(self): self.run_case("create_project.tcl", "already_exists")
    def test_regression_and_state_restore(self): self.run_case("regression.tcl")
    def test_regression_opens_expected_project(self): self.run_case("regression.tcl", "closed_project")
    def test_regression_rejects_wrong_project(self): self.run_case("regression.tcl", "wrong_project")
    def test_stale_pass_rejected(self): self.run_case("regression.tcl", "no_pass")
    def test_wrong_bench_pass_rejected(self): self.run_case("regression.tcl", "wrong_pass")
    def test_process_failure_restores_state(self): self.run_case("regression.tcl", "nonzero")
    def test_diagnostic_error_restores_state(self): self.run_case("regression.tcl", "diagnostic")
    def test_complete_report_export(self): self.run_case("export_reports.tcl")
    def test_export_opens_expected_project(self): self.run_case("export_reports.tcl", "closed_project")
    def test_stale_run_rejected(self): self.run_case("export_reports.tcl", "stale_synth")
    def test_unrouted_run_rejected(self): self.run_case("export_reports.tcl", "unrouted")
    def test_wrong_export_project_rejected(self): self.run_case("export_reports.tcl", "wrong_project")

    def test_memory_staging_stays_in_generated_directories(self):
        project = self.repo / "vivado/build/live_sampler"
        destinations = [project, project / "live_sampler.runs/synth_1",
                        project / "live_sampler.runs/impl_1", project / "live_sampler.sim/sim_1/behav/xsim"]
        for path in destinations:
            path.mkdir(parents=True, exist_ok=True)
        unrelated = self.repo / "unrelated_cwd"
        unrelated.mkdir()
        for index, cwd in enumerate((self.repo, unrelated)):
            original = self.repo / "samples/sample_a4.mem"
            original.write_text(f"{index:02X}\n")
            result = subprocess.run(["tclsh", str(self.repo / "vivado/stage_memory.tcl")],
                                    cwd=cwd, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for destination in destinations:
                self.assertEqual((destination / original.name).read_text(), original.read_text())
            self.assertFalse((self.repo / original.name).exists())
            self.assertFalse((unrelated / original.name).exists())

    def test_report_merger_has_exact_export_inputs(self):
        self.run_case("export_reports.tcl")
        report_dir = self.repo / "vivado/build/live_sampler/reports"
        exported = {path.name for path in report_dir.iterdir()}
        powershell = (ROOT / "tools/merge_reports.ps1").read_text()
        expected = re.search(r"\$expected = @\((.*?)\)", powershell, re.S).group(1)
        self.assertEqual(exported, set(re.findall(r'"([^"]+)"', expected)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
