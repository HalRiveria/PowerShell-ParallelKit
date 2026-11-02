# Stress runner for the cmdlet-hang question. Starts -Trials fresh
# powershell.exe processes running inner.ps1 (-Concurrency at a time). A trial
# still running after -TimeoutSec counts as a hang: the first -DumpFirst hung
# processes get a full memory dump, then it's killed.
#   powershell -NoProfile -File .\Testing\cmdlet-hang\run.ps1 -Mode Mixed -Trials 200
param(
    [Parameter(Mandatory)][string]$Mode,
    [int]$Trials = 100,
    [int]$Workers = 8,
    [int]$Rounds = 10,
    [int]$Concurrency = 3,
    [int]$TimeoutSec = 60,
    [int]$DumpFirst = 2,
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
if ($OutDir -eq '') { $OutDir = Join-Path $PSScriptRoot 'results' }

if (-not ('PkStressDump' -as [type])) {
    Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class PkStressDump {
    [DllImport("dbghelp.dll", SetLastError = true)]
    static extern bool MiniDumpWriteDump(IntPtr hProcess, uint processId, Microsoft.Win32.SafeHandles.SafeFileHandle hFile,
        uint dumpType, IntPtr exceptionParam, IntPtr userStreamParam, IntPtr callbackParam);
    public static bool Write(System.Diagnostics.Process p, string path) {
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.None)) {
            // MiniDumpWithFullMemory | MiniDumpWithHandleData | MiniDumpWithThreadInfo
            return MiniDumpWriteDump(p.Handle, (uint)p.Id, fs.SafeFileHandle, 0x2 | 0x4 | 0x1000, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        }
    }
}
'@
}

$kit   = (Resolve-Path (Join-Path $PSScriptRoot '..\..\ParallelKit.ps1')).Path
$inner = Join-Path $PSScriptRoot 'inner.ps1'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutDir ("$Mode-$stamp")
$null = New-Item -ItemType Directory -Path $runDir -Force

$results = [System.Collections.Generic.List[object]]::new()
$running = [System.Collections.Generic.List[hashtable]]::new()
$next = 1; $dumps = 0
$clock = [System.Diagnostics.Stopwatch]::StartNew()

while ($next -le $Trials -or $running.Count -gt 0) {
    while ($next -le $Trials -and $running.Count -lt $Concurrency) {
        $progress = Join-Path $runDir ("trial-$next.txt")
        $argLine = ('-NoProfile -File "{0}" -KitPath "{1}" -Mode {2} -Workers {3} -Rounds {4} -ProgressFile "{5}"' -f
            $inner, $kit, $Mode, $Workers, $Rounds, $progress)
        $p = Start-Process -FilePath powershell.exe -ArgumentList $argLine -WindowStyle Hidden -PassThru
        $running.Add(@{ Trial = $next; Proc = $p; Watch = [System.Diagnostics.Stopwatch]::StartNew(); Progress = $progress })
        $next++
    }
    Start-Sleep -Milliseconds 200
    foreach ($t in @($running)) {
        $outcome = $null
        if ($t.Proc.HasExited) {
            $outcome = switch ($t.Proc.ExitCode) { 0 { 'ok' } 3 { 'crash' } default { 'error' } }
        } elseif ($t.Watch.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $outcome = 'hang'
            if ($dumps -lt $DumpFirst) {
                $dumpPath = Join-Path $runDir ("trial-$($t.Trial)-pid$($t.Proc.Id).dmp")
                try { if ([PkStressDump]::Write($t.Proc, $dumpPath)) { $dumps++ } } catch { Write-Warning "dump failed: $_" }
            }
            try { $t.Proc.Kill() } catch { }  # it may have exited between the check and the kill
        }
        if ($null -eq $outcome) { continue }
        $lines = @(); if (Test-Path $t.Progress) { $lines = @(Get-Content $t.Progress) }
        $lastRound = ($lines | Where-Object { $_ -match '^round (\d+) start' } | Select-Object -Last 1) -replace '^round (\d+).*', '$1'
        $notes = ($lines | Where-Object { $_ -match 'gate-timeout|crash|error' }) -join ' | '
        if ($outcome -eq 'error') { $notes = ('exit 0x{0:X8} ' -f $t.Proc.ExitCode) + $notes }
        $results.Add([pscustomobject]@{ Trial = $t.Trial; Outcome = $outcome; Round = $lastRound; Seconds = [math]::Round($t.Watch.Elapsed.TotalSeconds, 1); Notes = $notes })
        if ($outcome -ne 'ok') { Write-Host ("trial {0}: {1} in round {2} {3}" -f $t.Trial, $outcome, $lastRound, $notes) -ForegroundColor Yellow }
        $null = $running.Remove($t)
    }
}

$results | Sort-Object Trial | Export-Csv -NoTypeInformation -Path (Join-Path $runDir 'results.csv')
$hangs = @($results | Where-Object Outcome -eq 'hang').Count
$other = @($results | Where-Object { $_.Outcome -ne 'ok' -and $_.Outcome -ne 'hang' }).Count
$gateTimeouts = @($results | Where-Object { $_.Notes -match 'gate-timeout' }).Count
$rounds = $Trials * $Rounds
"{0}: {1} hangs, {2} crash/error, {3} gate timeouts in {4} trials ({5} rounds of {6} workers) - {7:N0}s. Results: {8}" -f
    $Mode, $hangs, $other, $gateTimeouts, $Trials, $rounds, $Workers, $clock.Elapsed.TotalSeconds, $runDir
