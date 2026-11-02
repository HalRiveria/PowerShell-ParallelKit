# Stress runner for the ThreadJob / PoshRSJob scriptblock question. Starts
# -Trials fresh processes (-Exe powershell or pwsh) running inner.ps1,
# -Concurrency at a time. A trial still running after -TimeoutSec is a hang
# and is killed. Modules load from .\modules (saved with Save-PSResource, not
# installed).
#   powershell -NoProfile -File .\Testing\third-party\run.ps1 -Exe pwsh -Tool RSJob -Case Delegate -Main Wait -Trials 20
param(
    [Parameter(Mandatory)][ValidateSet('powershell', 'pwsh')][string]$Exe,
    [Parameter(Mandatory)][string]$Tool,
    [Parameter(Mandatory)][string]$Case,
    [string]$Via = 'Args',
    [string]$Main = 'Busy',
    [int]$Trials = 20,
    [int]$Workers = 8,
    [int]$Iterations = 2000,
    [int]$Concurrency = 3,
    [int]$TimeoutSec = 60,
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
if ($OutDir -eq '') { $OutDir = Join-Path $PSScriptRoot 'results' }

$inner = Join-Path $PSScriptRoot 'inner.ps1'
$modules = Join-Path $PSScriptRoot 'modules'
$label = "$Exe-$Tool-$Case-$Via-$Main"
$runDir = Join-Path $OutDir ($label + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$null = New-Item -ItemType Directory -Path $runDir -Force

$results = [System.Collections.Generic.List[object]]::new()
$running = [System.Collections.Generic.List[hashtable]]::new()
$next = 1
$clock = [System.Diagnostics.Stopwatch]::StartNew()

while ($next -le $Trials -or $running.Count -gt 0) {
    while ($next -le $Trials -and $running.Count -lt $Concurrency) {
        $progress = Join-Path $runDir ("trial-$next.txt")
        $argLine = ('-NoProfile -File "{0}" -Tool {1} -Case {2} -Via {3} -Main {4} -Workers {5} -Iterations {6} -WaitTimeoutSec {7} -ModuleDir "{8}" -ProgressFile "{9}"' -f
            $inner, $Tool, $Case, $Via, $Main, $Workers, $Iterations, ($TimeoutSec - 15), $modules, $progress)
        $p = Start-Process -FilePath "$Exe.exe" -ArgumentList $argLine -WindowStyle Hidden -PassThru
        $running.Add(@{ Trial = $next; Proc = $p; Watch = [System.Diagnostics.Stopwatch]::StartNew(); Progress = $progress })
        $next++
    }
    Start-Sleep -Milliseconds 200
    foreach ($t in @($running)) {
        $outcome = $null
        if ($t.Proc.HasExited) {
            $outcome = switch ($t.Proc.ExitCode) { 0 { 'ok' } 2 { 'wrong' } 4 { 'timeout' } default { 'crash' } }
        } elseif ($t.Watch.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $outcome = 'hang'
            try { $t.Proc.Kill() } catch { }  # it may have exited between the check and the kill
        }
        if ($null -eq $outcome) { continue }
        $lines = @(); if (Test-Path $t.Progress) { $lines = @(Get-Content $t.Progress) }
        $notes = ($lines | Where-Object { $_ -match '^(probe|timeout|job |iteration|odd|ok iter|main damage|exception|rsjob)' } | Select-Object -First 4) -join ' || '
        if ($outcome -eq 'crash') { $notes = ('exit 0x{0:X8} ' -f $t.Proc.ExitCode) + $notes }
        $results.Add([pscustomobject]@{ Trial = $t.Trial; Outcome = $outcome; Seconds = [math]::Round($t.Watch.Elapsed.TotalSeconds, 1); Notes = $notes })
        $null = $running.Remove($t)
    }
}

$results | Sort-Object Trial | Export-Csv -NoTypeInformation -Path (Join-Path $runDir 'results.csv')
$counts = ($results | Group-Object Outcome | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
$firstNote = ($results | Where-Object { $_.Outcome -ne 'ok' -or $_.Notes -like 'probe*' } | Sort-Object Trial | Select-Object -First 1).Notes
"{0}: {1} of {2} trials ({3:N0}s). {4}" -f $label, $counts, $Trials, $clock.Elapsed.TotalSeconds, $firstNote
