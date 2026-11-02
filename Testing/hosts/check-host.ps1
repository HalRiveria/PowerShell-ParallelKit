# Host check for ParallelKit: run this in the host you want to check (the
# ISE, the VS Code PowerShell terminal, a scheduled task) and look at the
# log it writes next to itself, check-host.log.
#
# Interactive hosts: when it says "press Ctrl+C now", press it once. A
# graceful abort shows "[ABORT] Ctrl+C detected" and the log ends with
# aborted=True and a time well under 30s. If Ctrl+C kills the script
# outright instead, the log stops at "batch started".
#
# Scheduled task: run it as
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<path>\check-host.ps1" -NoCtrlC
# and check that the log reaches "done".
param([switch]$NoCtrlC)

$log = Join-Path $PSScriptRoot 'check-host.log'
function Write-Log([string]$line) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $line); Write-Host $line }
Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue

try {
    Write-Log ("host: " + $Host.Name + " | PowerShell " + $PSVersionTable.PSVersion + " | interactive: " + [Environment]::UserInteractive)
    . (Join-Path $PSScriptRoot '..\..\ParallelKit.ps1')
    Write-Log "kit loaded"

    $init = Initialize-ParallelKit
    Write-Log ("Initialize-ParallelKit: AbortHandler=" + $init.AbortHandler + " ChildProcessJob=" + $init.ChildProcessJob + " ThreadPool=" + $init.ThreadPool)

    $ping = Join-Path $env:SystemRoot 'System32\ping.exe'
    $seconds = 30
    if ($NoCtrlC) { $seconds = 3 }
    $commands = @(1..2 | ForEach-Object { @{ FilePath = $ping; Arguments = ('-n ' + $seconds + ' 127.0.0.1') } })
    if (-not $NoCtrlC) { Write-Log ("press Ctrl+C now (the programs run for " + $seconds + "s)") }
    Write-Log "batch started"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $batch = Invoke-PkRun { Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 2 -AbortTimeoutSeconds 5 }
    Write-Log ("batch returned after " + [int]$sw.Elapsed.TotalSeconds + "s: aborted=" + $batch.Aborted + " results=" + $batch.Results.Count + " exit codes=" + (@($batch.Results | ForEach-Object { $_.ExitCode }) -join ','))

    Reset-PkAbortState
    $jobs = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -WorkerScript { param($Id) Write-PkMessage ("worker " + $Id); $Id * 10 } -ResultHandler { param($r) Write-Log ("worker result: " + $r) }
    Write-Log ("runspace jobs: crashed=" + $jobs.CrashedCount + " aborted=" + $jobs.Aborted)
    Write-Log "done"
} catch {
    Write-Log ("ERROR: " + $_)
}
