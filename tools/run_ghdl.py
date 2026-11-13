#!/usr/bin/env python3
"""Run the explicit Vivado source manifest with GHDL; retain logs and hashes."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ghdl", default="ghdl", help="GHDL executable or absolute path")
    parser.add_argument("--test", action="append",
                        help="Run this bench (including its variants), or one named variant; repeatable")
    args = parser.parse_args()
    executable = shutil.which(args.ghdl)
    if executable is None:
        parser.error("GHDL not found; install it or pass --ghdl PATH")
    root = Path(__file__).resolve().parents[1]
    manifest = (root / "vivado/sources.tcl").read_text(encoding="utf-8")

    def entries(name: str) -> list[str]:
        match = re.search(r"set\s+" + name + r"\s+\{([^}]*)\}", manifest, re.S)
        if match is None:
            raise ValueError(f"Missing static manifest list {name}")
        return match.group(1).split()

    rtl, benches, memories = (entries(n) for n in ("rtl_files", "tb_files", "memory_files"))
    names = [Path(p).stem for p in benches]
    cases = [(name, name, []) for name in names]
    for item in entries("regression_variants"):
        fields = item.split("|")
        if len(fields) != 3 or fields[1] not in names:
            parser.error(f"Invalid regression variant: {item}")
        case, bench, values = fields
        generics = values.split(",")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", case) or any(
                not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*=[-+A-Za-z0-9_.]+", value)
                for value in generics):
            parser.error(f"Invalid regression variant syntax: {item}")
        cases.append((case, bench, generics))
    case_names = [case for case, _, _ in cases]
    if len(case_names) != len(set(case_names)):
        parser.error("Duplicate regression case name")
    selected = set(args.test or case_names)
    if selected - set(case_names):
        parser.error("Unknown regression case: " + ", ".join(sorted(selected - set(case_names))))
    cases = [(case, bench, generics) for case, bench, generics in cases
             if case in selected or bench in selected]
    files = rtl + benches + memories
    for relative in files:
        if not (root / relative).is_file():
            parser.error(f"Missing source: {relative}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%f")
    work = root / "vivado/build/ghdl" / stamp
    work.mkdir(parents=True)
    for relative in memories:
        shutil.copyfile(root / relative, work / Path(relative).name)
    evidence = {"started_utc": stamp, "tool": executable, "tests": [],
                "manifest_sha256": hashlib.sha256((root / "vivado/sources.tcl").read_bytes()).hexdigest(),
                "source_sha256": {p: hashlib.sha256((root / p).read_bytes()).hexdigest()
                                  for p in files}}

    def run(arguments: list[str], name: str) -> str:
        command = [executable] + arguments
        result = subprocess.run(command, cwd=work, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120)
        (work / f"{name}.log").write_text(
            "$ " + " ".join(command) + "\n" + result.stdout, encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"{name} failed (exit {result.returncode}); see {work/name}.log")
        return result.stdout

    failed = False
    try:
        evidence["version"] = run(["--version"], "version")
        run(["-a", "--std=08"] + [str(root/p) for p in rtl + benches], "analyze")
        for case, name, generics in cases:
            run(["-e", "--std=08", name], case + "_elaborate")
            output = run(["-r", "--std=08", name] + ["-g" + value for value in generics]
                         + ["--assert-level=error"], case)
            if re.search(r"PASS:\s+" + re.escape(name) + r"(?=\s|$)", output) is None:
                raise RuntimeError(f"{case} stopped without PASS; see {work/case}.log")
            evidence["tests"].append({"name": case, "bench": name, "generics": generics,
                                      "status": "PASS", "log": case + ".log"})
            print(f"PASS: {case}", flush=True)
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        failed = True
        evidence["error"] = str(error)
        print(str(error), file=sys.stderr)
    evidence["status"] = "FAIL" if failed else "PASS"
    (work / "results.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(f"Evidence: {work}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
