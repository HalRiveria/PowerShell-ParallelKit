# Soak test: runs the kit for a long stretch and watches this PowerShell's
# handles, threads and memory after a garbage collection, round by round.
#
# Each round runs 250 programs through Invoke-PkProcessBatch: quick ones,
# ones that print more than a -MaxOutputChars cap, ones that leave a helper
# holding their output past -StreamTimeoutMs, and ones killed at a time
# limit. Then 100 runspace jobs through Invoke-PkRunspaceJobs. Helpers left
# holding output carry -w 4328 on their command line, and only those are
# killed between rounds.
#
#   powershell -NoProfile -File .\Testing\soak\run.ps1
#   pwsh -NoProfile -File .\Testing\soak\run.ps1
#
# Expected: SOAK PASSED, exit 0. Exits 1 if the counts after the warm-up
# rounds keep growing, or a round has start errors, aborts, runspace errors,
# or the wrong number of timed-out or capped programs. Takes about two
# minutes with the defaults. On Windows PowerShell 5.1, runspace jobs have
# been seen leaving a few handles behind each round (with version 3.3 too),
# so a full run there can fail on handles; -NoRunspace checks the programs
# on their own.
param(
    [int]$Rounds = 40,
    [int]$WarmupRounds = 5,
    [string]$KitPath = (Join-Path $PSScriptRoot '..\..\ParallelKit.ps1'),
    # To narrow a growth down: leave out the programs or the runspace jobs.
    [switch]$NoBatch,
    [switch]$NoRunspace,
    # For a kit before version 3.4, which has no -StreamTimeoutMs or
    # -MaxOutputChars.
    [switch]$Compat
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($WarmupRounds -lt 1 -or $Rounds -le $WarmupRounds) { throw "-Rounds ($Rounds) must be more than -WarmupRounds ($WarmupRounds), and -WarmupRounds at least 1: growth is measured from the end of the warm-up to the last round." }
. (Resolve-Path -LiteralPath $KitPath).ProviderPath
$null = Initialize-ParallelKit
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
$self = [System.Diagnostics.Process]::GetCurrentProcess()
function Stop-SoakHelpers {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE' AND CommandLine LIKE '%-w 4328 %'")) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }  # gone already is fine
    }
}
function Get-SoakCounts {
    [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
    $self.Refresh()
    return [pscustomobject]@{ Handles = $self.HandleCount; Threads = $self.Threads.Count; ManagedMB = [math]::Round([GC]::GetTotalMemory($true) / 1MB, 1); PrivateMB = [math]::Round($self.PrivateMemorySize64 / 1MB, 1) }
}
$commands = foreach ($i in 1..250) {
    switch ($i % 10) {
        0 { @{ FilePath = $cmd; Arguments = '/d /c for /l %i in (1,1,2000) do @echo line%i'; MaxOutputChars = 4000 } }
        1 { @{ FilePath = $cmd; Arguments = '/d /c echo held& start /b ping -n 3 -w 4328 127.0.0.1 >nul' } }
        2 { @{ FilePath = $cmd; Arguments = '/d /c ping -n 30 127.0.0.1 >nul'; TimeoutSeconds = 0.3 } }
        default { @{ FilePath = $cmd; Arguments = "/d /c echo $i" } }
    }
}
$jobParams = @(1..100 | ForEach-Object { @{ Id = $_ } })
$log = [System.Collections.Generic.List[object]]::new()
$start = Get-SoakCounts
"PS {0}, start: handles {1}, threads {2}, managed {3} MB, private {4} MB" -f $PSVersionTable.PSVersion, $start.Handles, $start.Threads, $start.ManagedMB, $start.PrivateMB
$total = [System.Diagnostics.Stopwatch]::StartNew()
try {
    for ($r = 1; $r -le $Rounds; $r++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $bad = 0; $timedOut = 25; $capped = 25; $rsErrors = 0
        if (-not $NoBatch) {
            $batchParams = @{ Commands = $commands; MaxConcurrent = 16 }
            if (-not $Compat) { $batchParams.StreamTimeoutMs = 500 }
            $b = Invoke-PkProcessBatch @batchParams
            $bad = @($b.Results | Where-Object { $_.StartError -or $_.Aborted }).Count
            $timedOut = @($b.Results | Where-Object { $_.TimedOut }).Count
            if (-not $Compat) { $capped = @($b.Results | Where-Object { $_.StdoutDroppedChars -gt 0 }).Count }
        }
        if (-not $NoRunspace) { $rsErrors = (Invoke-PkRunspaceJobs -MaxParallel 8 -JobParams $jobParams -WorkerScript { param($Id) $Id * 2 }).Errors.Count }
        Stop-SoakHelpers
        $c = Get-SoakCounts
        $row = [pscustomobject]@{ Round = $r; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Handles = $c.Handles; Threads = $c.Threads; ManagedMB = $c.ManagedMB; PrivateMB = $c.PrivateMB; Bad = $bad; TimedOut = $timedOut; Capped = $capped; RunspaceErrors = $rsErrors }
        $log.Add($row)
        "round {0,3}: {1,5} s  handles {2,6}  threads {3,4}  managed {4,7} MB  private {5,7} MB  (bad {6}, timed out {7}, capped {8}, runspace errors {9})" -f $row.Round, $row.Seconds, $row.Handles, $row.Threads, $row.ManagedMB, $row.PrivateMB, $row.Bad, $row.TimedOut, $row.Capped, $row.RunspaceErrors
    }
} finally { Stop-SoakHelpers }
$base = $log[$WarmupRounds - 1]
$last = $log[$log.Count - 1]
$problems = @()
if ($last.Handles -gt $base.Handles * 1.10 + 50) { $problems += "handles grew from $($base.Handles) to $($last.Handles)" }
if ($last.Threads -gt $base.Threads + 10) { $problems += "threads grew from $($base.Threads) to $($last.Threads)" }
if ($last.ManagedMB -gt $base.ManagedMB * 1.25 + 5) { $problems += "managed memory grew from $($base.ManagedMB) to $($last.ManagedMB) MB" }
if (@($log | Where-Object { $_.Bad -gt 0 -or $_.RunspaceErrors -gt 0 -or $_.TimedOut -ne 25 -or $_.Capped -ne 25 }).Count -gt 0) { $problems += "some rounds had start errors, aborts, runspace errors, or the wrong number of timed-out or capped programs" }
"{0} programs and {1} runspace jobs in {2:N0} s" -f $(if ($NoBatch) { 0 } else { $Rounds * $commands.Count }), $(if ($NoRunspace) { 0 } else { $Rounds * $jobParams.Count }), $total.Elapsed.TotalSeconds
if ($problems.Count -gt 0) { "SOAK FAILED: " + ($problems -join '; '); exit 1 }
"SOAK PASSED: after round $WarmupRounds, handles $($base.Handles) -> $($last.Handles), threads $($base.Threads) -> $($last.Threads), managed $($base.ManagedMB) -> $($last.ManagedMB) MB"
