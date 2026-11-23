# PowerShell 7 without the kit: what happens to programs run through
# ForEach-Object -Parallel in the cases the README's "Who it's for" lists?
# Nothing here loads ParallelKit. Each check runs a plain PowerShell 7 script,
# and passes when PowerShell behaves the way the README says it does:
#
#   1. Killed outright (taskkill /F, as Task Manager's End task does), the
#      script's programs keep running. The kit's own check of this is
#      Testing/force-kill, which expects none left.
#   2. -TimeoutSeconds doesn't stop a program that's already running: the
#      call returns only once the programs have ended on their own.
#   3. Ctrl+C stops the script and its running programs at once, even ones
#      that ignore Ctrl+C themselves: no wait for running work, and no
#      cleanup step for what was stopped.
#
#   pwsh -NoProfile -File .\Testing\ps7-native\run.ps1
#
# Check 3 sends a real Ctrl+C to a script in a hidden console of its own,
# never to yours. Expected: ALL PASSED. Takes about half a minute.
param([int]$ProgramSeconds = 20)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'This checks PowerShell 7 itself: run it with pwsh, not powershell.'
    exit 2
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("pk-ps7-native-" + $PID)
$null = New-Item -ItemType Directory -Path $work -Force
# A tag on each program's command line, so only this run's are counted. The
# scripts that start them get the tag without its 'prog' end.
$tag = 'pkps7native' + $PID
$progTag = $tag + 'prog'
$exe = (Get-Process -Id $PID).Path
# Start-Process doesn't quote -ArgumentList elements: paths are quoted by hand.
function Get-Quoted([string]$Path) { return '"' + $Path + '"' }
$pingCount = $ProgramSeconds + 1
$failures = 0
function Test-Check([bool]$Ok, [string]$What) {
    if ($Ok) { Write-Host "[PASS] $What" } else { Write-Host "[FAIL] $What"; $script:failures++ }
}
function Get-Tagged {
    # This run's programs: the cmd.exe running each ping, or the PowerShell that ignores Ctrl+C.
    @(Get-CimInstance Win32_Process | Where-Object { $null -ne $_.CommandLine -and $_.CommandLine.Contains($progTag) })
}
function Stop-Tagged {
    foreach ($p in Get-Tagged) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { $null -ne $_.CommandLine -and $_.CommandLine.Contains("-n $pingCount ") })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
function Wait-Tagged([int]$Count, [int]$Seconds = 30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline -and @(Get-Tagged).Count -lt $Count) { Start-Sleep -Milliseconds 200 }
    return @(Get-Tagged).Count
}
# The program each -Parallel iteration runs: cmd.exe running ping, tagged with a rem.
$program = '& cmd.exe /d /c "ping -n ' + $pingCount + ' 127.0.0.1 >nul & rem ' + $progTag + '"'

Write-Host ("PowerShell " + $PSVersionTable.PSVersion + ", no kit loaded")
try {
    # 1. Killed outright.
    $script1 = Join-Path $work 'killed.ps1'
    [IO.File]::WriteAllText($script1, ('1..3 | ForEach-Object -Parallel { ' + $program + ' } -ThrottleLimit 3'))
    $p1 = Start-Process $exe -ArgumentList '-NoProfile', '-File', (Get-Quoted $script1) -WindowStyle Hidden -PassThru
    $before = Wait-Tagged 3
    $null = & taskkill.exe /F /PID $p1.Id 2>&1   # PowerShell only, not its tree
    Start-Sleep -Seconds 2
    $after = @(Get-Tagged).Count
    Test-Check ($before -eq 3 -and $after -eq 3) "1. killed outright, PowerShell left its programs running ($after of $before still running)"
    Stop-Tagged

    # 2. -TimeoutSeconds.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $output = [System.Collections.Generic.List[string]]::new()
    try {
        1..3 | ForEach-Object -Parallel ([scriptblock]::Create($program + '; "ended on its own, exit $LASTEXITCODE"')) -ThrottleLimit 3 -TimeoutSeconds 3 | ForEach-Object { $output.Add([string]$_) }
    } catch {
        # -TimeoutSeconds ends the call with "The pipeline has been stopped."
        $output.Add('stopped: ' + $_.Exception.Message)
    }
    $sw.Stop()
    $ended = @($output | Where-Object { $_ -like 'ended on its own*' }).Count
    Test-Check ($sw.Elapsed.TotalSeconds -ge ($ProgramSeconds - 2) -and $ended -ge 1) ("2. -TimeoutSeconds 3 returned after " + [int]$sw.Elapsed.TotalSeconds + " s, once the programs had run their " + $ProgramSeconds + " s ($ended of 3 reported ending on their own)")
    Stop-Tagged

    # 3. Ctrl+C, to programs that ignore Ctrl+C themselves.
    $ignore = Join-Path $work 'ignore.ps1'
    [IO.File]::WriteAllText($ignore, @'
param([string]$Log, [string]$Tag, [int]$Seconds)
Add-Type -Name C -Namespace PkIgnoreCtrlC -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool add);'
$null = [PkIgnoreCtrlC.C]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
# A log of its own: three programs appending to one at once can collide.
$Log = $Log + '.' + $PID
[IO.File]::AppendAllText($Log, "ignoring Ctrl+C`r`n")
Start-Sleep -Seconds $Seconds
[IO.File]::AppendAllText($Log, "ran to the end`r`n")
'@)
    $log = Join-Path $work 'ctrlc.log'
    $script3 = Join-Path $work 'ctrlc.ps1'
    [IO.File]::WriteAllText($script3, @'
param([string]$Exe, [string]$Ignore, [string]$Log, [string]$Tag, [int]$Seconds)
# Started from a tool, this may inherit "ignore Ctrl+C"; a user's console doesn't. Clear it.
Add-Type -Name P -Namespace PkCtrlCTest -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool add);'
$null = [PkCtrlCTest.P]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
try {
    1..3 | ForEach-Object -Parallel { & $using:Exe -NoProfile -File $using:Ignore -Log $using:Log -Tag ($using:Tag + 'prog') -Seconds $using:Seconds } -ThrottleLimit 3
    [IO.File]::AppendAllText($Log, "script carried on after the pipeline`r`n")
} finally { [IO.File]::AppendAllText($Log, "script stopped`r`n") }
'@)
    $p3 = Start-Process $exe -ArgumentList '-NoProfile', '-File', (Get-Quoted $script3), '-Exe', (Get-Quoted $exe), '-Ignore', (Get-Quoted $ignore), '-Log', (Get-Quoted $log), '-Tag', $tag, '-Seconds', $ProgramSeconds -WindowStyle Hidden -PassThru
    $before = Wait-Tagged 3
    Start-Sleep -Seconds 1
    $sender = Join-Path $work 'sender.ps1'
    [IO.File]::WriteAllText($sender, @'
param([int]$TargetPid)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PkPs7NativeSender {
    public delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
    private static HandlerRoutine _swallow = new HandlerRoutine(Swallow);
    private static bool Swallow(uint ctrlType) { return true; }
    public static int Send(uint pid) {
        FreeConsole();
        if (!AttachConsole(pid)) { return 1; }
        // Attached to the same console, so this gets the Ctrl+C too.
        SetConsoleCtrlHandler(_swallow, true);
        if (!GenerateConsoleCtrlEvent(0, 0)) { return 2; }
        System.Threading.Thread.Sleep(300);
        FreeConsole();
        return 0;
    }
}
"@
exit [PkPs7NativeSender]::Send([uint32]$TargetPid)
'@)
    # In a hidden console of its own, so it can attach to the script's console.
    $s = Start-Process $exe -ArgumentList '-NoProfile', '-File', (Get-Quoted $sender), '-TargetPid', $p3.Id -WindowStyle Hidden -PassThru -Wait
    Start-Sleep -Seconds 2
    $p3.Refresh()
    $lines = @(foreach ($f in @(Get-ChildItem -Path ($log + '*') -File)) { Get-Content -LiteralPath $f.FullName })
    $left = @(Get-Tagged).Count
    Test-Check ($s.ExitCode -eq 0) "3. Ctrl+C sent (sender exit $($s.ExitCode))"
    Test-Check (@($lines | Where-Object { $_ -eq 'ignoring Ctrl+C' }).Count -eq 3) "3. the three programs were set to ignore Ctrl+C"
    Test-Check ($p3.HasExited -and ($lines -contains 'script stopped') -and -not ($lines -contains 'script carried on after the pipeline')) '3. Ctrl+C stopped the script'
    Test-Check ($before -eq 3 -and $left -eq 0 -and -not ($lines -contains 'ran to the end')) "3. its programs were stopped too, within 2 s, though they ignore Ctrl+C ($left of $before still running)"
    if (-not $p3.HasExited) { Stop-Process -Id $p3.Id -Force -ErrorAction SilentlyContinue }
} finally {
    # The scripts first, so none starts another program, then their programs.
    foreach ($p in @(Get-Variable -Name p1, p3 -ValueOnly -ErrorAction SilentlyContinue)) {
        if ($null -ne $p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Stop-Tagged
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures -eq 0) { Write-Host 'ALL PASSED' } else { Write-Host ($failures.ToString() + ' FAILED') }
exit $failures
