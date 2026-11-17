# Where does a PowerShell stop land? Behind two things the README relies on:
# a worker stuck inside a long .NET call can't be interrupted (Limits), and
# the dispatcher's bookkeeping steps (mark a job done, give back its shared
# slot) can't be split by a stop.
#
# A stop here is a real Ctrl+C that PowerShell itself handles (what a third
# press inside Invoke-PkRun becomes), or PowerShell.Stop() on a runspace (what
# the runspace engine's force-stop does). Each arrives while a 3 s .NET call
# is running, either sleeping or keeping a core busy. The call logs from C#
# when it starts, when it finishes, and any exception that passes through it.
# After the call, the script runs one step of each kind and records how far
# it got before the stop took effect.
#
# Expected, on 5.1 and 7: no call is interrupted (each runs its full time and
# Stop() waits for it), and the stop takes effect at the script function call
# in step 4, never between an assignment, an if/try or a .NET method call
# (steps 1 to 3). The last part runs the steps again after PowerShell has
# compiled them (it compiles code it runs repeatedly), with the same result.
#
# Each Ctrl+C case runs a child PowerShell in a hidden console of its own; a
# helper attaches to that console and sends the event there, as the harness's
# section V does. Nothing is sent to the console this runs in.
#   powershell -NoProfile -File .\Testing\stop-in-call\run.ps1
#   pwsh -NoProfile -File .\Testing\stop-in-call\run.ps1
param([int]$Rounds = 3, [int]$CallMs = 3000, [int]$WarmUp = 50)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$dir = Join-Path ([IO.Path]::GetTempPath()) ("pk-stopprobe-" + $PID)
$null = New-Item -ItemType Directory -Force -Path $dir
$probeCs = @'
using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
public static class PkStopProbe {
    public static string LogPath;
    public static void Log(string text) {
        try { File.AppendAllText(LogPath, DateTime.UtcNow.Ticks + " " + text + "\r\n"); } catch { }  // a lost line only shows as a missing step
    }
    // Stand-in for "mark the job, release its slot": two steps with a wait between.
    public static void Step(Hashtable job, int ms, bool spin) {
        job["Marked"] = true;
        Log("entered");
        try {
            if (spin) { Stopwatch sw = Stopwatch.StartNew(); while (sw.ElapsedMilliseconds < ms) { Thread.SpinWait(1000); } }
            else { Thread.Sleep(ms); }
        } catch (Exception e) { Log("exception " + e.GetType().Name); throw; }
        job["Released"] = true;
        Log("finished");
    }
    public delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
    [DllImport("kernel32.dll", EntryPoint = "SetConsoleCtrlHandler", SetLastError = true)] public static extern bool SetIgnoreCtrlC(IntPtr none, bool ignore);
    private static HandlerRoutine _h;
    public static bool RegisterEventProbe() { _h = new HandlerRoutine(OnEvent); return SetConsoleCtrlHandler(_h, true); }
    private static bool OnEvent(uint t) { Log("event " + t); return false; }  // false: PowerShell's own handler runs next
}
'@
$probeFile = Join-Path $dir 'probe.cs'
[IO.File]::WriteAllText($probeFile, $probeCs)

$childScript = Join-Path $dir 'child.ps1'
[IO.File]::WriteAllText($childScript, @'
param([string]$ProbeFile, [string]$LogFile, [int]$CallMs, [string]$Kind)
Set-StrictMode -Version Latest
Add-Type -TypeDefinition ([IO.File]::ReadAllText($ProbeFile))
[PkStopProbe]::LogPath = $LogFile
$null = [PkStopProbe]::SetIgnoreCtrlC([IntPtr]::Zero, $false)   # a process started from a tool may inherit "ignore Ctrl+C"
$null = [PkStopProbe]::RegisterEventProbe()
$job = @{}
$sem = [System.Threading.SemaphoreSlim]::new(0)
$shared = $true
function Test-Noop { $null = 1 }
try {
    [PkStopProbe]::Log("ready")
    [PkStopProbe]::Step($job, $CallMs, ($Kind -eq 'spin'))
    # The stop is pending from here on. Each step logs after it, so the last
    # "step" line is the last statement that ran before the stop landed.
    $job['SlotReleased'] = $true;                                         [PkStopProbe]::Log("step 1 assignment")
    if ($shared) { try { $null = $sem.Release() } catch { } };           [PkStopProbe]::Log("step 2 if/try/method call")
    try { if ($job['Proc']) { $null = 1 } } catch { };                    [PkStopProbe]::Log("step 3 try/if")
    Test-Noop;                                                            [PkStopProbe]::Log("step 4 script function call")
    foreach ($i in 1..3) { $null = $i };                                  [PkStopProbe]::Log("step 5 foreach")
    $null = Get-Date;                                                     [PkStopProbe]::Log("step 6 cmdlet call")
    Start-Sleep -Seconds 30
} finally {
    [PkStopProbe]::Log("finally Marked=" + [bool]$job['Marked'] + " Released=" + [bool]$job['Released'] + " SemCount=" + $sem.CurrentCount)
}
'@)

$senderScript = Join-Path $dir 'sender.ps1'
[IO.File]::WriteAllText($senderScript, @'
param([int]$TargetPid, [string]$LogFile)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PkProbeSender {
    public delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
    private static HandlerRoutine _swallow = new HandlerRoutine(Swallow);
    private static bool Swallow(uint ctrlType) { return true; }
    public static string Send(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) { return "attach-failed " + Marshal.GetLastWin32Error(); }
        SetConsoleCtrlHandler(_swallow, true);
        long at = DateTime.UtcNow.Ticks;
        if (!GenerateConsoleCtrlEvent(0, 0)) { return "send-failed " + Marshal.GetLastWin32Error(); }
        System.Threading.Thread.Sleep(300);
        FreeConsole();
        return "sent " + at;
    }
}
"@
[System.IO.File]::AppendAllText($LogFile, ([PkProbeSender]::Send([uint32]$TargetPid) + "`r`n"))
'@)

function Read-Lines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $fs = [IO.FileStream]::new($Path, 'Open', 'Read', 'ReadWrite')
        try { $t = [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return @() }   # caught mid-write; the next poll reads it
    return @($t -split "`r`n" | Where-Object { $_ })
}
function Find([object[]]$Lines, [string]$Like) {
    foreach ($l in $Lines) { $sp = $l.IndexOf(' '); if ($sp -gt 0 -and $l.Substring($sp + 1) -like $Like) { return $l } }
    return $null
}
function Ticks([string]$Line) { if ($Line) { return [int64]$Line.Substring(0, $Line.IndexOf(' ')) } else { return [int64]0 } }

$hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
Write-Host "=== runtime: $($PSVersionTable.PSVersion) ==="
$fails = 0; $skips = 0

# --- Real Ctrl+C in a child console -------------------------------------------
foreach ($kind in 'sleep', 'spin') {
    for ($r = 1; $r -le $Rounds; $r++) {
        $log = Join-Path $dir "$kind-$r.log"; $sendLog = "$log.send"
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$childScript`"", '-ProbeFile', "`"$probeFile`"", '-LogFile', "`"$log`"", '-CallMs', $CallMs, '-Kind', $kind)
        $child = Start-Process -FilePath $hostExe -ArgumentList $childArgs -WindowStyle Hidden -PassThru
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 30000 -and -not (Find (Read-Lines $log) 'entered')) { Start-Sleep -Milliseconds 50 }
        Start-Sleep -Milliseconds 800   # well inside the call
        $sender = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$senderScript`"", '-TargetPid', $child.Id, '-LogFile', "`"$sendLog`"") -WindowStyle Hidden -PassThru
        $null = $sender.WaitForExit(30000)
        $exited = $child.WaitForExit(20000)
        if (-not $exited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
        $lines = Read-Lines $log
        $sent = @(Read-Lines $sendLog) -join ' '
        $entered = Ticks (Find $lines 'entered'); $finished = Ticks (Find $lines 'finished'); $event = Ticks (Find $lines 'event 0')
        $exc = Find $lines 'exception *'; $steps = @($lines | Where-Object { $_ -like '* step *' }); $last = if ($steps.Count) { $steps[-1].Substring($steps[-1].IndexOf(' step ') + 1) } else { 'none' }; $fin = Find $lines 'finally *'
        $label = "Ctrl+C during a $kind call, round $r"
        if (-not $event) { $skips++; Write-Host "[SKIP] $label (event not delivered: $sent)" -ForegroundColor Yellow; continue }
        $eventInCall = $event -gt $entered -and ($finished -eq 0 -or $event -lt $finished)
        $ok = $exited -and $eventInCall -and $finished -gt 0 -and -not $exc -and $fin -like '*Marked=True Released=True SemCount=1'
        $detail = "(event +$([int](($event - $entered) / 10000)) ms, finished +$([int](($finished - $entered) / 10000)) ms, exception: $(if ($exc) { $exc } else { 'none' }), last statement before the stop: $last, $(if ($fin) { $fin.Substring($fin.IndexOf(' ') + 1) } else { 'no finally line' }), child exited: $exited)"
        if ($ok) { Write-Host "[PASS] $label $detail" } else { $fails++; Write-Host "[FAIL] $label $detail" -ForegroundColor Red }
    }
}

# --- PowerShell.Stop() on a runspace, same process ---------------------------
Add-Type -TypeDefinition $probeCs
[PkStopProbe]::LogPath = Join-Path $dir 'inproc.log'
foreach ($kind in 'sleep', 'spin') {
    for ($r = 1; $r -le $Rounds; $r++) {
        $job = [hashtable]::Synchronized(@{})
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({
            param($job, $ms, $spin)
            $sem = [System.Threading.SemaphoreSlim]::new(0); $shared = $true; $job['Sem'] = $sem
            function Test-Noop { $null = 1 }
            [PkStopProbe]::Step($job, $ms, $spin)
            $job['SlotReleased'] = $true;                               $job['Last'] = 'step 1 assignment'
            if ($shared) { try { $null = $sem.Release() } catch { } }; $job['Last'] = 'step 2 if/try/method call'
            try { if ($job['Proc']) { $null = 1 } } catch { };          $job['Last'] = 'step 3 try/if'
            Test-Noop;                                                  $job['Last'] = 'step 4 script function call'
            foreach ($i in 1..3) { $null = $i };                        $job['Last'] = 'step 5 foreach'
            $null = Get-Date;                                           $job['Last'] = 'step 6 cmdlet call'
            Start-Sleep -Seconds 30
        }).AddArgument($job).AddArgument($CallMs).AddArgument($kind -eq 'spin')
        $async = $ps.BeginInvoke()
        $w = [Diagnostics.Stopwatch]::StartNew()
        while (-not $job['Marked'] -and $w.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20 }
        Start-Sleep -Milliseconds 800
        $stopAt = [Diagnostics.Stopwatch]::StartNew()
        $ps.Stop()
        $stopMs = $stopAt.ElapsedMilliseconds
        $state = $ps.InvocationStateInfo.State
        $ps.Dispose()
        $semCount = $job['Sem'].CurrentCount
        $ok = [bool]$job['Marked'] -and [bool]$job['Released'] -and $semCount -eq 1 -and $state -eq 'Stopped'
        $label = "PowerShell.Stop() during a $kind call, round $r"
        $detail = "(Stop() took $stopMs ms, Released=$([bool]$job['Released']), last statement before the stop: $($job['Last']), SemCount=$semCount, state $state)"
        if ($ok) { Write-Host "[PASS] $label $detail" } else { $fails++; Write-Host "[FAIL] $label $detail" -ForegroundColor Red }
    }
}
$exc = Find (Read-Lines ([PkStopProbe]::LogPath)) 'exception *'
if ($exc) { $fails++; Write-Host "[FAIL] in-process: an exception went through the call: $exc" -ForegroundColor Red }

# --- The same, with the steps already compiled ---------------------------------
for ($r = 1; $r -le $Rounds; $r++) {
    $job = [hashtable]::Synchronized(@{})
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript({
        param($job, $ms, $warm)
        function Test-Noop { $null = 1 }
        function Invoke-Steps($job, $ms, $sem) {
            [PkStopProbe]::Step($job, $ms, $false)
            $job['SlotReleased'] = $true;                               $job['Last'] = 'step 1 assignment'
            if ($true) { try { $null = $sem.Release() } catch { } };   $job['Last'] = 'step 2 if/try/method call'
            try { if ($job['Proc']) { $null = 1 } } catch { };          $job['Last'] = 'step 3 try/if'
            Test-Noop;                                                  $job['Last'] = 'step 4 script function call'
            foreach ($i in 1..3) { $null = $i };                        $job['Last'] = 'step 5 foreach'
        }
        $warmSem = [System.Threading.SemaphoreSlim]::new(0)
        for ($i = 0; $i -lt $warm; $i++) { Invoke-Steps @{} 0 $warmSem }   # run enough times that PowerShell compiles it
        $sem = [System.Threading.SemaphoreSlim]::new(0); $job['Sem'] = $sem
        Invoke-Steps $job $ms $sem
        Start-Sleep -Seconds 30
    }).AddArgument($job).AddArgument($CallMs).AddArgument($WarmUp)
    $async = $ps.BeginInvoke()
    $w = [Diagnostics.Stopwatch]::StartNew()
    while (-not $job['Marked'] -and $w.ElapsedMilliseconds -lt 30000) { Start-Sleep -Milliseconds 20 }
    Start-Sleep -Milliseconds 800
    $ps.Stop()
    $state = $ps.InvocationStateInfo.State
    $ps.Dispose()
    $semCount = $job['Sem'].CurrentCount
    $ok = [bool]$job['Released'] -and $semCount -eq 1 -and $state -eq 'Stopped'
    $label = "PowerShell.Stop() during a compiled call, round $r"
    $detail = "(warm-up $WarmUp runs, last statement before the stop: $($job['Last']), SemCount=$semCount, state $state)"
    if ($ok) { Write-Host "[PASS] $label $detail" } else { $fails++; Write-Host "[FAIL] $label $detail" -ForegroundColor Red }
}

Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
if ($fails) { Write-Host "$fails FAILED, $skips skipped"; exit 1 }
Write-Host "ALL PASSED ($skips skipped)"; exit 0
