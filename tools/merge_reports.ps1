# Run after a successful vivado/export_reports.tcl export.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ReportDirectory,
    [Parameter(Position = 1)]
    [string]$OutputPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$directory = Get-Item -LiteralPath $ReportDirectory
if (-not $directory.PSIsContainer -or $directory.PSProvider.Name -ne "FileSystem") {
    throw "ReportDirectory must be a filesystem directory."
}
$expected = @(
    "provenance.txt",
    "synth_utilization.rpt", "synth_timing.rpt", "synth_drc.rpt", "synth_runme.log",
    "impl_utilization.rpt", "impl_timing.rpt", "impl_drc.rpt", "impl_runme.log",
    "impl_route.rpt", "impl_io.rpt", "impl_clocks.rpt", "impl_cdc.rpt",
    "impl_methodology.rpt"
)
$inputs = @($expected | ForEach-Object { Join-Path $directory.FullName $_ })
$missing = @($inputs | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missing.Count -ne 0) {
    throw ("Incomplete export; missing files:`n" + ($missing -join "`n"))
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $directory.FullName "merged_reports.txt"
}
$target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ($inputs -icontains $target) {
    throw "OutputPath must not overwrite an input report."
}
$merged = [System.Text.StringBuilder]::new()
[void]$merged.AppendLine("FPGA Sampler Synthesizer - Vivado report bundle")
[void]$merged.AppendLine("Report directory: $($directory.FullName)")
for ($index = 0; $index -lt $expected.Count; $index++) {
    [void]$merged.AppendLine()
    [void]$merged.AppendLine(("=" * 78))
    [void]$merged.AppendLine($expected[$index])
    [void]$merged.AppendLine(("=" * 78))
    [void]$merged.AppendLine([System.IO.File]::ReadAllText($inputs[$index]))
}
[void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
[System.IO.File]::WriteAllText($target, $merged.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host "Merged $($expected.Count) reports into $target"
