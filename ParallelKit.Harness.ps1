# Test harness for ParallelKit.ps1. Real runspaces and real child processes
# (cmd.exe / ping.exe), nothing mocked.
#
#   powershell -NoProfile -File .\ParallelKit.Harness.ps1
#
# Exit code 0 = all passed, 1 = any failed.

$ErrorActionPreference = "Stop"
# The whole suite runs under strict mode: a host project may well use it,
# and the kit must not depend on lenient hashtable/variable reads.
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "ParallelKit.ps1")

$script:passCount = 0
$script:failCount = 0
$script:skipCount = 0
# A few checks need things only some machines have (a console of their own,
# say). Where they can't run they print [SKIP] with the reason. Set
# PK_HARNESS_NO_SKIP=1 to count every skip as a failure instead.
$script:noSkip = ($env:PK_HARNESS_NO_SKIP -eq '1')

function Test-Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:passCount++
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
    } else {
        $script:failCount++
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
    }
}

function Test-Skip {
    param([string]$Message)
    if ($script:noSkip) {
        $script:failCount++
        Write-Host ("  [FAIL] " + $Message + " (skipping isn't allowed: PK_HARNESS_NO_SKIP=1)") -ForegroundColor Red
    } else {
        $script:skipCount++
        Write-Host ("  [SKIP] " + $Message) -ForegroundColor Yellow
    }
}

# Every message the kit emits lands here instead of on the console.
$script:messages = [System.Collections.Generic.List[hashtable]]::new()
$messageSink = $script:messages
Set-PkMessageHandler -Handler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()

function Reset-Harness {
    Reset-PkAbortState
    $script:messages.Clear()
}

function New-JobList {
    param([hashtable[]]$Jobs)
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($j in $Jobs) { $list.Add($j) }
    return ,$list
}

$cmdExe  = Join-Path $env:SystemRoot "System32\cmd.exe"
# Whichever PowerShell is running the harness (powershell.exe or pwsh.exe),
# for the tests that need a fresh process of the same version.
$selfExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$pingExe = Join-Path $env:SystemRoot "System32\ping.exe"

# A user function the workers share.
function Get-HarnessDouble {
    param([int]$Value)
    return ($Value * 2)
}

# ==============================================================================
Write-Host "=== A: setup ===" -ForegroundColor Cyan
$init = Initialize-ParallelKit -MaxConcurrentProcesses 8
Test-Assert ($init.AbortHandler -eq $true)    "abort handler registers"
Test-Assert ($init.ChildProcessJob -eq $true) "child-process job object initializes"
Test-Assert ($init.ThreadPool -eq $true)      "thread pool minimum is raised"
$w = 0; $io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
Test-Assert ($w -ge 128) "thread pool minimum is at least 128 worker threads"
Write-Host ""

# ==============================================================================
Write-Host "=== B: runspace jobs - results, concurrency cap, messages, shared functions ===" -ForegroundColor Cyan
Reset-Harness
$track = @{ Cur = 0; Max = 0 }
$gate  = [object]::new()
$worker = {
    param([int]$Id, $Track, $Gate)
    [System.Threading.Monitor]::Enter($Gate)
    try { $Track.Cur++; if ($Track.Cur -gt $Track.Max) { $Track.Max = $Track.Cur } } finally { [System.Threading.Monitor]::Exit($Gate) }
    [System.Threading.Thread]::Sleep(300)
    [System.Threading.Monitor]::Enter($Gate)
    try { $Track.Cur-- } finally { [System.Threading.Monitor]::Exit($Gate) }
    Write-PkMessage ("worker " + $Id + " done")
    return @{ Id = $Id; Doubled = (Get-HarnessDouble -Value $Id) }
}
$jobs = New-JobList -Jobs @(1..8 | ForEach-Object { @{ Id = $_; Track = $track; Gate = $gate } })
$results = [System.Collections.Generic.List[hashtable]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript $worker -JobParams $jobs -MaxParallel 3 -SharedFunctionNames @('Get-HarnessDouble') `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() -CheckWorkerSafety
Test-Assert ($results.Count -eq 8) "all 8 jobs return a result"
$sum = 0; foreach ($r in $results) { $sum += $r.Doubled }
Test-Assert ($sum -eq 72) "the shared user function ran inside the workers (sum of doubles = 72)"
Test-Assert ($track.Max -le 3 -and $track.Max -ge 2) ("never more than MaxParallel workers at once (peak " + $track.Max + ")")
Test-Assert (@($script:messages | Where-Object { $_.Message -like 'worker * done' }).Count -eq 8) "all 8 worker messages reach the main-thread handler"
Test-Assert ($out.CrashedCount -eq 0 -and -not $out.Aborted -and $out.ForceStoppedCount -eq 0) "a clean run reports no crashes, no abort, nothing force-stopped"
Test-Assert ([PkState]::SourceCount -eq 0) "the run's own cancellation source is unregistered afterwards"
Write-Host ""

# ==============================================================================
Write-Host "=== C: runspace jobs - lazy provider, crash handling, bad input ===" -ForegroundColor Cyan
Reset-Harness
$feed = @{ Next = 1 }
$provider = { if ($feed.Next -gt 5) { return $null }; $j = @{ Id = $feed.Next }; $feed.Next++; return $j }.GetNewClosure()
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) return $Id } -NextJobProvider $provider -MaxParallel 2 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 5) "-NextJobProvider feeds jobs until it returns null"

$crashes = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
$jobs = New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })
$out = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) if ($Id -eq 2) { throw "boom" }; return $Id } -JobParams $jobs -MaxParallel 2 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() -JobCrashedHandler { param($e) $crashes.Add($e) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 1 -and $crashes.Count -eq 1) "a worker that throws is counted and reported to -JobCrashedHandler"
Test-Assert ($results.Count -eq 2) "the other workers still return their results"
Test-Assert (@($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like '*boom*' }).Count -eq 1) "the crash is reported as an Error message"

# Which job crashed: on the return object, and to a handler that asks for it.
$crashedProp = $out.PSObject.Properties['Crashed']   # read safely: strict mode throws on a missing property
Test-Assert ($null -ne $crashedProp -and @($crashedProp.Value).Count -eq 1 -and $crashedProp.Value[0].Job['Id'] -eq 2 -and $crashedProp.Value[0].Error -is [System.Management.Automation.ErrorRecord]) "the return object lists the crashed job and its error"
$crashWorker = { param([int]$Id) if ($Id -eq 2) { throw "boom" }; return $Id }
$seenJobs = [System.Collections.Generic.List[object]]::new()
$null = Invoke-PkRunspaceJobs -WorkerScript $crashWorker -JobParams $jobs -MaxParallel 2 -JobCrashedHandler { param($e, $job) $seenJobs.Add($job) }.GetNewClosure()
Test-Assert ($seenJobs.Count -eq 1 -and $null -ne $seenJobs[0] -and $seenJobs[0]['Id'] -eq 2) "a -JobCrashedHandler with a second parameter gets the job that crashed"
$seenArgs = @{ Count = -1; Id = $null }
$null = Invoke-PkRunspaceJobs -WorkerScript $crashWorker -JobParams $jobs -MaxParallel 2 -JobCrashedHandler { $seenArgs.Count = $args.Count; $seenArgs.Id = $args[1]['Id'] }.GetNewClosure()
Test-Assert ($seenArgs.Count -eq 2 -and $seenArgs.Id -eq 2) ("a -JobCrashedHandler with no param() gets the error and the job in `$args (count " + $seenArgs.Count + ")")
# One-parameter handlers that would throw on a second argument still work.
$advanced = @{ Calls = 0 }
$null = Invoke-PkRunspaceJobs -WorkerScript $crashWorker -JobParams $jobs -MaxParallel 2 -JobCrashedHandler { [CmdletBinding()] param($e) $advanced.Calls++ }.GetNewClosure()
Test-Assert ($advanced.Calls -eq 1) "a one-parameter [CmdletBinding()] -JobCrashedHandler is still called"
function Receive-HarnessCrash($e, $job) { $script:harnessCrashId = $job['Id'] }
$script:harnessCrashId = $null
$null = Invoke-PkRunspaceJobs -WorkerScript $crashWorker -JobParams $jobs -MaxParallel 2 -JobCrashedHandler ${function:Receive-HarnessCrash}
Test-Assert ($script:harnessCrashId -eq 2) "a function used as -JobCrashedHandler, with function f(`$e, `$job) parameters, gets the job"
# A handler that throws is reported, not swallowed.
Reset-Harness
$null = Invoke-PkRunspaceJobs -WorkerScript $crashWorker -JobParams $jobs -MaxParallel 2 -JobCrashedHandler { param($e) throw "handler bug" }
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*-JobCrashedHandler threw*handler bug*' }).Count -eq 1) "a -JobCrashedHandler that throws is reported as a message"
# Workers that throw while an abort waits for them count as crashes too.
Reset-Harness
$poll = @{ Count = 0 }
$drainCrashes = [System.Collections.Generic.List[object]]::new()
$drainOut = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 })) -WorkerScript {
    param([int]$Id)
    for ($i = 0; $i -lt 100; $i++) { if (Test-PkCancelRequested) { break }; [System.Threading.Thread]::Sleep(50) }
    [System.Threading.Thread]::Sleep(500)
    throw ("drain boom " + $Id)
} -PollCallback { $poll.Count++; if ($poll.Count -eq 3) { Request-PkAbort } }.GetNewClosure() -JobCrashedHandler { param($e, $job) $drainCrashes.Add($job['Id']) }.GetNewClosure()
$drainCrashedProp = $drainOut.PSObject.Properties['Crashed']
Test-Assert ($drainOut.Aborted -and $drainOut.CrashedCount -eq 2 -and $null -ne $drainCrashedProp -and @($drainCrashedProp.Value).Count -eq 2 -and $drainCrashes.Count -eq 2) ("workers that throw during an abort's drain are counted and reported (counted " + $drainOut.CrashedCount + ", handler calls " + $drainCrashes.Count + ")")
Reset-Harness

$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 -SharedFunctionNames @('No-SuchFunction') } catch { $threw = ($_.ToString() -like "*No-SuchFunction*") }
Test-Assert $threw "an unknown -SharedFunctionNames entry fails up front with the name in the message"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) } -JobParams (New-JobList -Jobs @(@{ Id = 1; Extra = 2 })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*Extra*") }
Test-Assert $threw "a job key the worker doesn't declare fails with a clear message"
$emptyOut = Invoke-PkRunspaceJobs -WorkerScript { param($Id) } -JobParams ([System.Collections.Generic.List[hashtable]]::new()) -MaxParallel 1
Test-Assert ($emptyOut.CrashedCount -eq 0 -and -not $emptyOut.Aborted) "an empty job list returns immediately"
Write-Host ""

# ==============================================================================
Write-Host "=== D: runspace jobs - abort ===" -ForegroundColor Cyan
Reset-Harness
# Cooperative workers: stop as soon as they see the cancel.
$worker = {
    param([int]$Id, $CancelToken)
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-PkCancelRequested) { return @{ Id = $Id; Stopped = $true; TokenSeen = ($CancelToken -is [System.Threading.CancellationToken] -and $CancelToken.CanBeCanceled) } }
        [System.Threading.Thread]::Sleep(100)
    }
    return @{ Id = $Id; Stopped = $false }
}
$jobs = New-JobList -Jobs @(1..6 | ForEach-Object { @{ Id = $_ } })
$results = [System.Collections.Generic.List[hashtable]]::new()
$poll = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -WorkerScript $worker -JobParams $jobs -MaxParallel 2 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 5) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($out.Aborted -eq $true) "an abort mid-run is reported as Aborted"
Test-Assert ($results.Count -eq 2) ("only the 2 in-flight workers ran; the other 4 never started (got " + $results.Count + ")")
Test-Assert (@($results | Where-Object { $_.Stopped }).Count -eq 2) "in-flight workers saw the cancel and stopped early"
Test-Assert (@($results | Where-Object { $_.TokenSeen }).Count -eq 2) "a declared `$CancelToken parameter receives the run's token"
Test-Assert ($out.ForceStoppedCount -eq 0) "cooperative workers are not force-stopped"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 8) ("the run ends promptly after the abort (" + [int]$sw.Elapsed.TotalSeconds + "s)")
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Abort requested*' }).Count -eq 1) "the abort is announced exactly once"

# A worker that ignores the cancel gets force-stopped after the drain timeout.
Reset-Harness
$poll = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) [System.Threading.Thread]::Sleep(6000); return $Id } `
    -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 })) -MaxParallel 2 -DrainTimeoutSeconds 1 `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 3) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($out.ForceStoppedCount -eq 2) "workers that ignore the cancel are force-stopped after the drain timeout"
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Force-stopping 2 job(s)*' }).Count -eq 1) "the force-stop is announced"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 4) ("force-stopped workers are abandoned, not waited for (took " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s; the workers sleep 6s)")
Write-Host ""

# ==============================================================================
Write-Host "=== E: single processes ===" -ForegroundColor Cyan
Reset-Harness
$r = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c echo hello& echo oops 1>&2& exit 3'
Test-Assert ($r.ExitCode -eq 3) "exit code is captured"
Test-Assert ($r.Stdout.Trim() -eq 'hello') "stdout is captured"
Test-Assert ($r.Stderr.Trim() -eq 'oops') "stderr is captured"
$threw = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 800 } catch { $threw = ($_.ToString() -like '*did not exit within*') }
$sw.Stop()
Test-Assert ($threw -and $sw.Elapsed.TotalSeconds -lt 6) "a process that overruns its time limit is killed and reported"
# A -TimeoutMs below 1 is refused before anything starts, not taken as a
# limit that's already used up.
foreach ($badMs in 0, -5) {
    $badMsError = $null
    try { $null = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c exit 0' -TimeoutMs $badMs } catch { $badMsError = $_.ToString() }
    Test-Assert ($badMsError -like '*-TimeoutMs must be at least 1*') ("-TimeoutMs " + $badMs + " is refused with a clear message (error: " + $badMsError + ")")
}
$threw = $false
try { $null = Start-PkProcess -FilePath 'C:\no\such\program.exe' } catch { $threw = ($_.ToString() -like "*could not start*") }
Test-Assert $threw "a program that can't be started throws a clear error (not a silent null)"
$j = Start-PkProcess -FilePath $cmdExe -Arguments '/c exit 0'
$null = Wait-PkProcess -Process $j.Proc -TimeoutMs 5000
Test-Assert ([PkChildProcessJob]::Assign($j.Proc) -or $j.Proc.HasExited) "started processes are tied to the job object"
$j.Proc.Dispose()

# ConvertTo-PkArgumentString: exact output for the tricky cases, then a
# round trip through a real program that prints each argument it received.
Test-Assert ((ConvertTo-PkArgumentString @('plain', 'two words', '')) -eq 'plain "two words" ""') "arguments with spaces are quoted, empty ones become `"`""
Test-Assert ((ConvertTo-PkArgumentString @('C:\dir with space\')) -eq '"C:\dir with space\\"') "a trailing backslash is doubled inside quotes"
Test-Assert ((ConvertTo-PkArgumentString @('say "hi"', 'a\"b')) -eq '"say \"hi\"" "a\\\"b"') "quotes are escaped, and backslashes before them doubled"
Test-Assert ((ConvertTo-PkArgumentString @('C:\no\spaces\')) -eq 'C:\no\spaces\') "an argument that needs no quotes is left alone"
# Built with the .NET Framework's csc.exe (on every Windows machine) rather
# than Add-Type, which can't build an .exe under PowerShell 7.
$argvExe = Join-Path $env:TEMP ("pk-argv-" + [guid]::NewGuid().ToString("N") + ".exe")
$argvSrc = [System.IO.Path]::ChangeExtension($argvExe, '.cs')
[System.IO.File]::WriteAllText($argvSrc, 'public static class PkArgv { public static void Main(string[] args) { foreach (string a in args) { System.Console.WriteLine("[" + a + "]"); } } }')
$cscExe = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$csc = $null
try { $csc = Invoke-PkProcessWithTimeout -FilePath $cscExe -Arguments (ConvertTo-PkArgumentString @('/nologo', ('/out:' + $argvExe), $argvSrc)) } catch { Write-Host "  csc.exe failed to run: $_" }
[System.IO.File]::Delete($argvSrc)
$compiled = ($null -ne $csc -and $csc.ExitCode -eq 0 -and [System.IO.File]::Exists($argvExe))
Test-Assert $compiled "the argument-printing test program compiles"
if ($compiled) {
    $tricky = @('plain', 'two words', '', 'C:\dir with space\', 'say "hi"', 'a\"b', 'tab	here', 'x\\y', '\\server\share\')
    $r = Invoke-PkProcessWithTimeout -FilePath $argvExe -Arguments (ConvertTo-PkArgumentString $tricky)
    $received = @(([string]$r.Stdout).Split([string[]]@("`r`n"), [System.StringSplitOptions]::RemoveEmptyEntries))
    $expected = @($tricky | ForEach-Object { "[" + $_ + "]" })
    Test-Assert (($received -join '|') -eq ($expected -join '|')) ("a program receives exactly the arguments given (got " + ($received -join ' ') + ")")
    try { [System.IO.File]::Delete($argvExe) } catch { }  # temp file only; best effort
}

# -OutputEncoding: a program that writes UTF-8 bytes comes back intact when
# told so, and garbled when decoded as code page 437 (a default console).
$u8Exe = Join-Path $env:TEMP ("pk-u8-" + [guid]::NewGuid().ToString("N") + ".exe")
$u8Src = [System.IO.Path]::ChangeExtension($u8Exe, '.cs')
[System.IO.File]::WriteAllText($u8Src, 'public static class PkU8 { public static void Main() { string t = new string(new char[] { (char)0x63, (char)0x61, (char)0x66, (char)0xE9, (char)0x20, (char)0x65E5, (char)0x672C, (char)0x8A9E }); byte[] b = new System.Text.UTF8Encoding(false).GetBytes(t); var o = System.Console.OpenStandardOutput(); o.Write(b, 0, b.Length); o.Flush(); var e = System.Console.OpenStandardError(); e.Write(b, 0, b.Length); e.Flush(); } }')
$csc = $null
try { $csc = Invoke-PkProcessWithTimeout -FilePath $cscExe -Arguments (ConvertTo-PkArgumentString @('/nologo', ('/out:' + $u8Exe), $u8Src)) } catch { Write-Host "  csc.exe failed to run: $_" }
[System.IO.File]::Delete($u8Src)
$compiled = ($null -ne $csc -and $csc.ExitCode -eq 0 -and [System.IO.File]::Exists($u8Exe))
Test-Assert $compiled "the UTF-8 test program compiles"
if ($compiled) {
    $u8Text = 'caf' + [char]0xE9 + ' ' + [char]0x65E5 + [char]0x672C + [char]0x8A9E
    $r = Invoke-PkProcessWithTimeout -FilePath $u8Exe -OutputEncoding 'utf-8'
    $codes = { param($s) (([string]$s).ToCharArray() | ForEach-Object { '{0:X4}' -f [int]$_ }) -join ' ' }
    Test-Assert ($r.Stdout -eq $u8Text -and $r.Stderr -eq $u8Text) ("-OutputEncoding 'utf-8' decodes a program's UTF-8 output, stdout and stderr (got " + (& $codes $r.Stdout) + " / " + (& $codes $r.Stderr) + ")")
    $r = Invoke-PkProcessWithTimeout -FilePath $u8Exe -OutputEncoding 437
    Test-Assert ($r.Stdout -ne $u8Text) "and decoding it as code page 437 garbles it, so the option really takes effect"
    $batch = Invoke-PkProcessBatch -OutputEncoding 'utf8' -Commands @(@{ FilePath = $u8Exe; Name = 'default' }, @{ FilePath = $u8Exe; Name = 'own'; OutputEncoding = 437 })
    $byName = @{}; foreach ($br in $batch.Results) { $byName[$br.Command['Name']] = $br.Stdout }
    Test-Assert ($byName['default'] -eq $u8Text -and $byName['own'] -ne $u8Text) "batch: -OutputEncoding applies to every command, and a command's own OutputEncoding key overrides it"
    try { [System.IO.File]::Delete($u8Exe) } catch { }  # temp file only; best effort
}
Test-Assert ((& (Get-Module ParallelKit) Resolve-PkEncoding -Encoding '437').CodePage -eq 437) "a code page given as text ('437') is accepted"
# -OutputEncoding mustn't replace PowerShell's own $OutputEncoding inside the
# caller's callbacks.
$seen = @{ Value = 'unset' }
$null = Invoke-PkProcessBatch -OutputEncoding 'utf-8' -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -OnComplete { param($c, $r) $seen.Value = $OutputEncoding }.GetNewClosure()
Test-Assert ($seen.Value -is [System.Text.Encoding]) ("inside -OnComplete, `$OutputEncoding is still PowerShell's own (got [" + $seen.Value + "])")
$seen.Value = 'unset'
$null = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -OnComplete { param($c, $r) $seen.Value = $OutputEncoding }
Test-Assert ($seen.Value -is [System.Text.Encoding]) ("and in an -OnComplete without .GetNewClosure() too (got [" + $seen.Value + "])")
$threw = $false
try { $null = Invoke-PkProcessBatch -OutputEncoding 'no-such-encoding' -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) } catch { $threw = ($_.ToString() -like "*'no-such-encoding' isn't an encoding*") }
Test-Assert $threw "an unknown -OutputEncoding fails the call with a clear message"
Write-Host ""

# ==============================================================================
Write-Host "=== F: process batch ===" -ForegroundColor Cyan
Reset-Harness
$commands = @(0..5 | ForEach-Object { @{ FilePath = $cmdExe; Arguments = ('/c echo item' + $_ + '& exit ' + $_); Tag = $_ } })
$commands += @{ FilePath = 'C:\no\such\program.exe'; Arguments = ''; Tag = 99 }
$seen = [System.Collections.Generic.List[int]]::new()
$batch = Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 3 -OnComplete { param($c, $r) $seen.Add($c.Tag) }.GetNewClosure()
Test-Assert ($batch.Results.Count -eq 7) "every command gets a result"
$byTag = @{}; foreach ($r in $batch.Results) { $byTag[$r.Command.Tag] = $r }
Test-Assert ($byTag[4].ExitCode -eq 4 -and $byTag[4].Stdout.Trim() -eq 'item4') "each result carries its own command, exit code and output"
Test-Assert ($null -eq $byTag[99].ExitCode -and $byTag[99].StartError) "a command that can't start is reported, not dropped"
Test-Assert ($seen.Count -eq 6) "-OnComplete fires for each command that ran"
Test-Assert (-not $batch.Aborted) "a clean batch is not marked aborted"
$wd = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c cd'; WorkingDirectory = $env:SystemRoot }) -MaxConcurrent 1
Test-Assert ($wd.Results[0].Stdout.Trim() -ieq $env:SystemRoot) "a command's WorkingDirectory is honored"
# A foreach over nothing yields $null, not an empty array - the usual way to build the list when no files match.
$noCommands = foreach ($x in @()) { @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }
$emptyBatch = $null
try { $emptyBatch = Invoke-PkProcessBatch -Commands $noCommands -MaxConcurrent 2 } catch { Write-Host "  empty batch threw: $_" }
Test-Assert ($null -ne $emptyBatch -and $emptyBatch.Results.Count -eq 0 -and -not $emptyBatch.Aborted) "a batch given `$null (an empty foreach) returns no results"
Write-Host ""

# ==============================================================================
Write-Host "=== G: process dispatch - groups, limits, retries ===" -ForegroundColor Cyan
Reset-Harness
# 4 groups: 3 jobs, 0 jobs, 2 jobs, 1 job (which is retried once).
$groupDefs = @(
    @{ Name = 'g1'; Count = 3 }, @{ Name = 'g2'; Count = 0 }, @{ Name = 'g3'; Count = 2 }, @{ Name = 'g4'; Count = 1; Retry = $true }
)
$feed = @{ Index = 0 }
$track = @{ Max = 0; Finalized = 0; Retried = 0 }
$completed = [System.Collections.Generic.List[string]]::new()
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 2 -MaxQueueAhead 2 `
    -GroupProvider { if ($feed.Index -ge $groupDefs.Count) { return $null }; $g = $groupDefs[$feed.Index]; $feed.Index++; return $g }.GetNewClosure() `
    -JobBuilder {
        param($group)
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        for ($i = 0; $i -lt $group.Count; $i++) { $jobs.Add(@{ FilePath = $pingExe; Arguments = '-n 2 127.0.0.1'; Retry = [bool]$group.Retry }) }
        return $jobs
    }.GetNewClosure() `
    -PollCallback { param($running) if ($running.Count -gt $track.Max) { $track.Max = $running.Count } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $r = Complete-PkProcess -Job $job
        if ($job.Retry) {
            $track.Retried++
            $pending.Enqueue(@{ FilePath = $pingExe; Arguments = '-n 1 127.0.0.1'; Retry = $false; GroupKey = $job.GroupKey })
            return @{ Requeued = $true }
        }
        $track.Finalized++
        return @{ Success = ($r.ExitCode -eq 0) }
    }.GetNewClosure() `
    -GroupCompleteCallback { param($group) $completed.Add($group.Name) }.GetNewClosure()
Test-Assert ($track.Finalized -eq 6) ("all 6 jobs are finalized, the retried one once (got " + $track.Finalized + ")")
Test-Assert ($track.Retried -eq 1) "a job that returns Requeued is run again"
Test-Assert ($track.Max -eq 2) ("never more than MaxConcurrent processes at once (peak " + $track.Max + ")")
Test-Assert ($completed.Count -eq 4 -and ($completed -contains 'g2')) "every group completes, including the zero-job one"
Test-Assert ($completed.IndexOf('g4') -eq 3) "a group with a requeued job completes only after the retry finishes"
Test-Assert ($dispatch.GroupResults.Count -eq 4 -and -not $dispatch.Aborted) "one result per group, not aborted"
Test-Assert ([PkState]::SourceCount -eq 0) "the dispatcher's own cancellation source is unregistered afterwards"

# A job that can't start is counted and its group still completes.
Reset-Harness
$feed = @{ Given = $false }
$completed = [System.Collections.Generic.List[string]]::new()
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'bad' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = 'C:\no\such\program.exe'; Arguments = '' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -GroupCompleteCallback { param($group) $completed.Add($group.Name) }.GetNewClosure()
Test-Assert ($dispatch.JobStarterFailedCount -eq 1) "a job that fails to start is counted"
Test-Assert ($completed.Count -eq 1) "its group still completes once the other job finishes"
Test-Assert (@($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like '*JobStarter failed*' }).Count -eq 1) "the start failure is reported as an Error message"

foreach ($bad in @(0, -1, 'x')) {
    $threw = $false
    try { $null = Invoke-PkProcessDispatch -MaxConcurrent $bad -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) } } catch { $threw = ($_.ToString() -like '*-MaxConcurrent must be*') }
    Test-Assert $threw ("-MaxConcurrent '" + $bad + "' is refused up front instead of spinning forever")
}
$threw = $false
try { $null = Invoke-PkProcessDispatch -MaxConcurrent 1 -MaxQueueAhead 0 -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) } } catch { $threw = ($_.ToString() -like '*-MaxQueueAhead must be*') }
Test-Assert $threw "-MaxQueueAhead 0 is refused up front"

# Zero-job groups hold their queue-ahead slot until released.
Reset-Harness
$feed = @{ Index = 0 }
$released = [System.Collections.Generic.HashSet[int]]::new()
$pulledAtFirstRelease = @{ Value = -1 }
$ticks = @{ Count = 0 }
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 1 -MaxQueueAhead 2 `
    -GroupProvider { if ($feed.Index -ge 6) { return $null }; $g = @{ Id = $feed.Index }; $feed.Index++; return $g }.GetNewClosure() `
    -JobBuilder { param($g) return @() } `
    -JobFinalize { param($job, $pending) } `
    -GroupReleaseCheck { param($g) return $released.Contains($g.Id) }.GetNewClosure() `
    -PollCallback {
        param($running)
        $ticks.Count++
        if ($ticks.Count -eq 4) { $pulledAtFirstRelease.Value = $feed.Index }
        if ($ticks.Count -ge 4) { for ($i = 0; $i -lt 6; $i++) { $null = $released.Add($i) } }
    }.GetNewClosure()
Test-Assert ($pulledAtFirstRelease.Value -eq 2) ("with -GroupReleaseCheck, zero-job groups can't run ahead of MaxQueueAhead (pulled " + $pulledAtFirstRelease.Value + " before release)")
Test-Assert ($dispatch.GroupResults.Count -eq 6) "all groups complete once released"
Write-Host ""

# ==============================================================================
Write-Host "=== H: process dispatch - abort ===" -ForegroundColor Cyan
Reset-Harness
$feed = @{ Given = $false }
$cleaned = @{ Count = 0 }
$ticks = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$dispatch = Invoke-PkProcessDispatch -MaxConcurrent 2 -AbortTimeoutSeconds 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'slow' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(1..5 | ForEach-Object { @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' } }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -JobAbortCleanup { param($job) $cleaned.Count++ }.GetNewClosure() `
    -PollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 6) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($dispatch.Aborted) "an abort mid-dispatch is reported as Aborted"
Test-Assert ($dispatch.ForceKilledCount -eq 2) "the 2 running processes are force-killed after the abort timeout"
Test-Assert ($cleaned.Count -eq 5) ("-JobAbortCleanup runs for killed AND never-started jobs (got " + $cleaned.Count + ")")
Test-Assert ($dispatch -is [System.Management.Automation.PSCustomObject]) "the dispatcher returns exactly one result object, even on the force-kill path"
Test-Assert ($dispatch.GroupResults.Count -eq 1 -and $dispatch.GroupResults[0].Aborted) "the unfinished group is reported as aborted"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 15) ("the dispatcher returns promptly (" + [int]$sw.Elapsed.TotalSeconds + "s), not after 30s of ping")
Write-Host ""

# ==============================================================================
Write-Host "=== I: dispatchers inside workers, sharing one process budget ===" -ForegroundColor Cyan
Reset-Harness
# Two "engines", each its own runspace running its own dispatcher, both
# drawing on one shared SemaphoreSlim of 2.
$budget = [System.Threading.SemaphoreSlim]::new(2, 2)
$engine = {
    param([string]$Name, [System.Threading.SemaphoreSlim]$Budget, [string]$PingExe, $Peak)
    $feed = @{ Index = 0 }
    $done = @{ Count = 0 }
    $dispatch = Invoke-PkProcessDispatch -MaxConcurrent $Budget `
        -GroupProvider { if ($feed.Index -ge 2) { return $null }; $feed.Index++; return @{ Id = $feed.Index } }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $PingExe; Arguments = '-n 2 127.0.0.1' }, @{ FilePath = $PingExe; Arguments = '-n 2 127.0.0.1' }) }.GetNewClosure() `
        -PollCallback { param($running) $inUse = 2 - $Budget.CurrentCount; if ($inUse -gt $Peak.Max) { $Peak.Max = $inUse } }.GetNewClosure() `
        -JobFinalize { param($job, $pending) $r = Complete-PkProcess -Job $job; if ($r.ExitCode -eq 0) { $done.Count++ } }.GetNewClosure()
    Write-PkMessage ("engine " + $Name + " finished " + $done.Count)
    return @{ Name = $Name; Done = $done.Count; Aborted = $dispatch.Aborted }
}
$peak = @{ Max = 0 }
$results = [System.Collections.Generic.List[hashtable]]::new()
$jobs = New-JobList -Jobs @(@{ Name = 'A'; Budget = $budget; PingExe = $pingExe; Peak = $peak }, @{ Name = 'B'; Budget = $budget; PingExe = $pingExe; Peak = $peak })
$out = Invoke-PkRunspaceJobs -WorkerScript $engine -JobParams $jobs -MaxParallel 2 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() -CheckWorkerSafety
Test-Assert ($out.CrashedCount -eq 0) "dispatchers run inside worker runspaces without crashing"
$total = 0; foreach ($r in $results) { $total += $r.Done }
Test-Assert ($total -eq 8) ("both engines finish all their processes (8 total, got " + $total + ")")
Test-Assert ($peak.Max -le 2) ("the shared budget is never exceeded across both engines (peak " + $peak.Max + ")")
Test-Assert ($budget.CurrentCount -eq 2) "every budget slot is handed back"
Test-Assert (@($script:messages | Where-Object { $_.Message -like 'engine * finished 4' }).Count -eq 2) "messages written inside the engines reach the main thread"
$budget.Dispose()
Write-Host ""

# ==============================================================================
# Many threads registering/unregistering cancellation sources at once.
$churn = {
    param([int]$Id)
    for ($i = 0; $i -lt 300; $i++) {
        $c = [System.Threading.CancellationTokenSource]::new()
        Register-PkCancellationSource -Cts $c
        Unregister-PkCancellationSource -Cts $c
        $c.Dispose()
    }
    return $Id
}
$before = [PkState]::SourceCount
$churnOut = Invoke-PkRunspaceJobs -WorkerScript $churn -JobParams (New-JobList -Jobs @(1..6 | ForEach-Object { @{ Id = $_ } })) -MaxParallel 6
Test-Assert ($churnOut.CrashedCount -eq 0 -and [PkState]::SourceCount -eq $before) "cancellation sources can be registered and unregistered from 6 workers at once"
Write-Host ""

# ==============================================================================
Write-Host "=== J: Invoke-PkRun bracket ===" -ForegroundColor Cyan
Reset-Harness
$inside = @{ RunActive = $false }
$value = Invoke-PkRun -ScriptBlock { $inside.RunActive = [PkConsoleCtrl]::RunActive; return 42 }.GetNewClosure()
Test-Assert ($inside.RunActive -eq $true) "the handler is armed while the run's scriptblock executes"
Test-Assert ([PkConsoleCtrl]::RunActive -eq $false) "and disarmed afterwards"
Test-Assert ($value -eq 42) "the scriptblock's output passes through"
Test-Assert ([PkConsoleCtrl]::DrainComplete.IsSet) "the drain is marked complete on the way out"
$threw = $false
try { Invoke-PkRun -ScriptBlock { throw "inner" } } catch { $threw = $true }
Test-Assert ($threw -and [PkConsoleCtrl]::RunActive -eq $false) "an exception still disarms the handler"
# Nested runs: the inner one must not disarm or reset the outer one.
$nested = @{ AfterInner = $false; AbortKept = $false; Inner = 0 }
Invoke-PkRun -ScriptBlock {
    Request-PkAbort
    $nested.Inner = Invoke-PkRun -ScriptBlock { return 7 }
    $nested.AfterInner = [PkConsoleCtrl]::RunActive
    $nested.AbortKept  = [PkConsoleCtrl]::AbortRequested
}.GetNewClosure()
Test-Assert ($nested.Inner -eq 7) "a nested Invoke-PkRun still runs its scriptblock and passes its output through"
Test-Assert ($nested.AfterInner -eq $true) "the outer run stays armed after a nested run ends"
Test-Assert ($nested.AbortKept -eq $true) "a nested run does not wipe the outer run's abort state"
Test-Assert ([PkConsoleCtrl]::RunActive -eq $false) "the outer run still disarms at its own end"
# A stale abort from a previous run must not leak into the next one.
Request-PkAbort
$null = Test-PkAbortSignal
$leaked = Invoke-PkRun -ScriptBlock { return (Test-PkAbortSignal) }
Test-Assert ($leaked -eq $false) "each run starts with a clean abort state"
Write-Host ""

# Every public function has Get-Help help: a synopsis, and a description for
# each of its parameters. The same list is the Export-ModuleMember list at the
# end of ParallelKit.ps1; keep the two in step.
$publicFunctions = @('Set-PkMessageHandler', 'Write-PkMessage', 'Initialize-ParallelKit', 'Register-PkCancellationSource',
    'Unregister-PkCancellationSource', 'Reset-PkAbortState', 'Request-PkAbort', 'Test-PkAbortSignal', 'Test-PkCancelRequested',
    'Get-PkAbortTriggerLabel', 'Invoke-PkRun', 'ConvertTo-PkArgumentString', 'Start-PkProcess', 'Stop-PkProcessTree',
    'Wait-PkProcess', 'Complete-PkProcess', 'Invoke-PkProcessWithTimeout', 'Invoke-PkProcessDispatch', 'Invoke-PkProcessBatch',
    'Invoke-PkRunspaceJobs', 'Test-PkWorkerSafety')
$helpGaps = foreach ($fn in $publicFunctions) {
    $help = Get-Help -Name $fn -Full
    if ([string]::IsNullOrWhiteSpace([string]$help.Synopsis) -or ([string]$help.Synopsis).Trim().StartsWith($fn)) { $fn + ': no synopsis' }
    foreach ($p in (Get-Command -Name $fn).Parameters.Keys) {
        if ($p -in [System.Management.Automation.PSCmdlet]::CommonParameters) { continue }
        $ph = @($help.parameters.parameter | Where-Object { $_.name -eq $p })
        $desc = ''
        if ($ph.Count -gt 0 -and $null -ne $ph[0].PSObject.Properties['description']) { $desc = ($ph[0].description | ForEach-Object { $_.Text }) -join '' }
        if ([string]::IsNullOrWhiteSpace($desc)) { $fn + ' -' + $p }
    }
}
Test-Assert (@($helpGaps).Count -eq 0) ("every public function has Get-Help help for itself and each parameter (missing: " + (@($helpGaps) -join ', ') + ")")

# ==============================================================================
Write-Host "=== K: worker-safety check ===" -ForegroundColor Cyan
Reset-Harness
function Get-HarnessUnsafeState { return $script:someState }
function Get-HarnessUsesCmdlet  { return (Get-Date) }
function Get-HarnessCallsOther  { return (Get-HarnessDouble -Value 2) }
function Get-HarnessDelegate    { return [Func[int]]{ 1 } }
function Get-HarnessIgnored     { return $script:someState }  # pk:ignore

$f = Test-PkWorkerSafety -WorkerScript { param($Id) return (Get-HarnessDouble -Value $Id) } -SharedFunctionNames @('Get-HarnessDouble')
Test-Assert ($f.Count -eq 0) "clean worker code produces no findings"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) return (Get-HarnessDouble -Value $Id) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'MissingFunction') "a worker calling an unshared function is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessCallsOther } -SharedFunctionNames @('Get-HarnessCallsOther')
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'MissingFunction' -and $f[0].Where -eq 'function Get-HarnessCallsOther') "a shared function calling an unshared one is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessUnsafeState } -SharedFunctionNames @('Get-HarnessUnsafeState')
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'ScriptVariable') "a shared function using `$script: is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $script:top = 1; $sb = { $script:nested = 2 } }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'ScriptVariable') "in the worker body, only `$script: inside a nested scriptblock is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Start-Sleep -Milliseconds 5; @(1, 2) | Where-Object { $_ -gt 1 } | ForEach-Object { $_ }; Get-HarnessUsesCmdlet } -SharedFunctionNames @('Get-HarnessUsesCmdlet')
Test-Assert ($f.Count -eq 0) ("cmdlets, including ones that take a scriptblock, pass the check in the worker body and in shared functions (got " + $f.Count + " finding(s))")
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessDelegate } -SharedFunctionNames @('Get-HarnessDelegate')
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock-to-delegate cast is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-HarnessIgnored } -SharedFunctionNames @('Get-HarnessIgnored')
Test-Assert ($f.Count -eq 0) "'# pk:ignore' on the line accepts a finding"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Write-PkMessage "x"; if (Test-PkCancelRequested) { return }; $null = Start-PkProcess -FilePath 'x' }
Test-Assert ($f.Count -eq 0) "the kit's own worker functions never need listing"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) $null = [Func[int]]{ 1 } } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 -CheckWorkerSafety } catch { $threw = ($_.ToString() -like '*Func*') }
Test-Assert $threw "-CheckWorkerSafety refuses to launch unsafe worker code, naming the problem"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Id) $null = [Func[int]]{ 1 } } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like '*Func*') }
Test-Assert $threw "the worker-safety check runs without being asked"
$out = $null
try { $out = Invoke-PkRunspaceJobs -WorkerScript { param($Id) $null = [Func[int]]{ 1 } } -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 -CheckWorkerSafety:$false } catch { Write-Host "  opt-out threw: $_" }
Test-Assert ($null -ne $out -and $out.CrashedCount -eq 0) "-CheckWorkerSafety:`$false turns the check off"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param($Id) return @(1, 2, 3) | Where-Object { $_ -gt 1 } | Measure-Object -Sum | ForEach-Object { $_.Sum + $Id } } `
    -JobParams (New-JobList -Jobs @(@{ Id = 10 }, @{ Id = 20 })) -MaxParallel 2 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and (@($results | Sort-Object) -join ',') -eq '15,25') "workers can run cmdlets, including ones that take a scriptblock"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param($Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } `
    -JobParams (New-JobList -Jobs @(@{ Path = $cmdExe })) -MaxParallel 1 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and $results.Count -eq 1 -and $results[0] -eq (Get-FileHash -LiteralPath $cmdExe -Algorithm SHA256).Hash) "a function from a module (Get-FileHash) needn't be shared, and autoloads in the worker"

# A scriptblock passed as a job value runs against the main thread's session
# state - refused at launch, with the pass-as-text workaround.
$mainThreadBlock = { param($x) $x * 2 }
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Fn) } -JobParams (New-JobList -Jobs @(@{ Fn = 'ok' }, @{ Fn = $mainThreadBlock })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*job 1*'Fn'*Create*Nothing was started*") }
Test-Assert $threw "a scriptblock job value is refused before any worker starts, naming the job and key"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Fns) } -JobParams (New-JobList -Jobs @(@{ Fns = @(1, $mainThreadBlock) })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*'Fns'*") }
Test-Assert $threw "a scriptblock inside an array job value is refused too"
$threw = $false
$providerState = @{ Given = 0 }
$provider = { if ($providerState.Given -ge 2) { return $null }; $providerState.Given++; if ($providerState.Given -eq 2) { return @{ Fn = $mainThreadBlock } }; return @{ Fn = 'ok' } }.GetNewClosure()
try { $null = Invoke-PkRunspaceJobs -WorkerScript { param($Fn) } -NextJobProvider $provider -MaxParallel 1 } catch { $threw = ($_.ToString() -like "*-NextJobProvider*'Fn'*") }
Test-Assert $threw "a scriptblock job value from -NextJobProvider is refused"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -WorkerScript { param($FnText, $Id) $fn = [scriptblock]::Create($FnText); return (& $fn $Id) } `
    -JobParams (New-JobList -Jobs @(@{ FnText = $mainThreadBlock.ToString(); Id = 4 })) -MaxParallel 1 -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and $results.Count -eq 1 -and $results[0] -eq 8) "the pass-as-text workaround runs"
Write-Host ""

# ==============================================================================
Write-Host "=== L: message handler ===" -ForegroundColor Cyan
Reset-Harness
Write-PkMessage "main-thread message" -Level Warn
Test-Assert ($script:messages.Count -eq 1 -and $script:messages[0].Level -eq 'Warn') "on the main thread, Write-PkMessage goes straight to the handler"
$closure = { Write-PkMessage "from a closure" }.GetNewClosure()
& $closure
Test-Assert ($script:messages.Count -eq 2) "the handler is still found when called from inside a .GetNewClosure()'d block"
Write-Host ""

# ==============================================================================
Write-Host "=== M: callbacks that output things ===" -ForegroundColor Cyan
Reset-Harness
# Every callback below emits stray output. None of it may reach a return value.
$poll = @{ Count = 0 }
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(1..4 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) for ($i = 0; $i -lt 50; $i++) { if (Test-PkCancelRequested) { return $Id }; [System.Threading.Thread]::Sleep(100) }; return $Id } `
    -ResultHandler { param($r) $true; 123 } `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 4) { Request-PkAbort }; "noise" }.GetNewClosure()
Test-Assert ($out -is [System.Management.Automation.PSCustomObject] -and $out.Aborted) "runspace jobs: noisy -ResultHandler/-PollCallback don't corrupt the result, even through an abort drain"

Reset-Harness
$crashOut = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -WorkerScript { param($Id) throw "x" } -JobCrashedHandler { param($e) "noise"; 5 }
Test-Assert ($crashOut -is [System.Management.Automation.PSCustomObject] -and $crashOut.CrashedCount -eq 1) "runspace jobs: a noisy -JobCrashedHandler doesn't corrupt the result"

Reset-Harness
$feed = @{ Given = $false }; $ticks = @{ Count = 0 }
$noisy = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'n' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }, @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -JobAbortCleanup { param($job) "noise"; $true } `
    -GroupCompleteCallback { param($group) "noise"; 1 } `
    -PollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 5) { Request-PkAbort }; "noise" }.GetNewClosure()
Test-Assert ($noisy -is [System.Management.Automation.PSCustomObject] -and $noisy.ForceKilledCount -eq 1) "dispatch: noisy -JobAbortCleanup/-GroupCompleteCallback/-PollCallback don't corrupt the result"

Reset-Harness
$noisyBatch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 1 -OnComplete { param($c, $r) "noise"; $true }
Test-Assert ($noisyBatch -is [System.Management.Automation.PSCustomObject] -and $noisyBatch.Results.Count -eq 1) "batch: a noisy -OnComplete doesn't corrupt the result"

Set-PkMessageHandler -Handler { param($Message, $Level) "noise"; 42 }
$leaked = Write-PkMessage "hello"
Test-Assert ($null -eq $leaked) "a message handler's output doesn't leak out of Write-PkMessage"
Set-PkMessageHandler -Handler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()
Write-Host ""

# ==============================================================================
Write-Host "=== N: careless job starters and retries ===" -ForegroundColor Cyan
Reset-Harness
function Invoke-HarnessOneGroupDispatch {
    # One group, $JobCount jobs, with the given starter/finalize.
    param([scriptblock]$JobStarter, [scriptblock]$JobFinalize, [int]$JobCount = 1, [hashtable]$Done)
    $feed = @{ Given = $false }
    $count = $JobCount
    return Invoke-PkProcessDispatch -MaxConcurrent 2 -AbortTimeoutSeconds 2 -JobStarter $JobStarter -JobFinalize $JobFinalize `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'one' } }.GetNewClosure() `
        -JobBuilder { param($g) return @(1..$count | ForEach-Object { @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }) }.GetNewClosure() `
        -GroupCompleteCallback { param($group) $Done.Groups++ }.GetNewClosure()
}

# Fills in the job it was given but forgets to return it.
$done = @{ Groups = 0; Jobs = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobCount 2 `
    -JobStarter { param($job) $s = Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments; $job.Proc = $s.Proc; $job.StdoutTask = $s.StdoutTask; $job.StderrTask = $s.StderrTask } `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++ }.GetNewClosure()
$sw.Stop()
Test-Assert ($done.Jobs -eq 2 -and $done.Groups -eq 1) "a starter that fills in the job but forgets to return it still works"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 10) "and the dispatcher doesn't hang on it"

# Returns the job, but with stray output in front of it.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0 }
$d = Invoke-HarnessOneGroupDispatch -Done $done `
    -JobStarter { param($job) "noise"; $s = Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments; $job.Proc = $s.Proc; $job.StdoutTask = $s.StdoutTask; $job.StderrTask = $s.StderrTask; return $job } `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++ }.GetNewClosure()
Test-Assert ($done.Jobs -eq 1 -and $d.JobStarterFailedCount -eq 0) "a starter that leaks output before the job is still understood"

# Never starts anything at all.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobStarter { param($job) return $job } -JobFinalize { param($job, $pending) $done.Jobs++ }.GetNewClosure()
$sw.Stop()
Test-Assert ($d.JobStarterFailedCount -eq 1 -and $done.Groups -eq 1 -and $sw.Elapsed.TotalSeconds -lt 10) "a starter that never sets .Proc is reported as a failed start instead of spinning forever"
Test-Assert (@($script:messages | Where-Object { $_.Message -like "*did not set the job's .Proc*" }).Count -eq 1) "with a message saying what the starter got wrong"

# A retry job enqueued without its GroupKey.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0; Retried = $false }
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobStarter $null -JobFinalize {
    param($job, $pending)
    $null = Complete-PkProcess -Job $job
    if (-not $done.Retried) {
        $done.Retried = $true
        $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })   # no GroupKey copied
        return @{ Requeued = $true }
    }
    $done.Jobs++
}.GetNewClosure()
Test-Assert ($done.Jobs -eq 1 -and $done.Groups -eq 1 -and -not $d.Aborted) "a retry job enqueued without its GroupKey is still credited to the right group"

# Complete-PkProcess on a job with no read tasks.
$bare = Start-PkProcess -FilePath $cmdExe -Arguments '/c exit 5'
$null = Wait-PkProcess -Process $bare.Proc -TimeoutMs 5000
$threw = $false
try { $bareResult = Complete-PkProcess -Job @{ Proc = $bare.Proc } } catch { $threw = $true }
Test-Assert (-not $threw -and $bareResult.ExitCode -eq 5 -and $null -eq $bareResult.Stdout) "Complete-PkProcess copes with a job that has no output-read tasks"
$bare.Proc.Dispose()
Write-Host ""

# ==============================================================================
Write-Host "=== O: aborts and the caller's own tokens ===" -ForegroundColor Cyan
Reset-Harness
# A caller-supplied source is canceled by an abort, and left registered nowhere.
$mine = [System.Threading.CancellationTokenSource]::new()
$poll = @{ Count = 0 }
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -Cts $mine -JobParams (New-JobList -Jobs @(1..6 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) for ($i = 0; $i -lt 50; $i++) { if (Test-PkCancelRequested) { return $Id }; [System.Threading.Thread]::Sleep(100) }; return $Id } `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 4) { Request-PkAbort } }.GetNewClosure()
Test-Assert ($out.Aborted -and $mine.IsCancellationRequested) "runspace jobs: an abort cancels a caller-supplied -Cts"
Test-Assert ($results.Count -eq 2) ("so the remaining jobs are not launched (ran " + $results.Count + " of 6)")
Test-Assert ([PkState]::SourceCount -eq 0) "and the caller's source is not left registered"
$mine.Dispose()

Reset-Harness
$mine = [System.Threading.CancellationTokenSource]::new()
$feed = @{ Given = $false }; $ticks = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 -CancelToken $mine.Token `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'c' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(1..3 | ForEach-Object { @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' } }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -PollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 5) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($d.Aborted -and $sw.Elapsed.TotalSeconds -lt 15) "dispatch: an abort stops a run that was given the caller's own -CancelToken"
Test-Assert (-not $mine.IsCancellationRequested) "without canceling the caller's own token"
Test-Assert ([PkState]::SourceCount -eq 0) "and nothing is left registered"

# ...and the caller's token still works as a cancel.
Reset-Harness
$feed = @{ Given = $false }; $ticks = @{ Count = 0 }
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 -CancelToken $mine.Token `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'c2' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -PollCallback { param($running) $ticks.Count++; if ($ticks.Count -eq 5) { $mine.Cancel() } }.GetNewClosure()
Test-Assert ($d.Aborted -and $d.ForceKilledCount -eq 1) "dispatch: canceling the caller's own token still stops the run"
$mine.Dispose()

# An abort stays in force until it is reset.
Reset-Harness
Request-PkAbort
$null = Test-PkAbortSignal
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(1..4 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) if (Test-PkCancelRequested) { return }; return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.Aborted -eq $true -and $results.Count -eq 0) "a run started while an earlier abort is still in force reports Aborted instead of silently doing nothing"
$batchAfter = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 1
Test-Assert ($batchAfter.Aborted -eq $true) "the same goes for a process batch"
Reset-PkAbortState
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(1..4 | ForEach-Object { @{ Id = $_ } })) `
    -WorkerScript { param([int]$Id) if (Test-PkCancelRequested) { return }; return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert (-not $out.Aborted -and $results.Count -eq 4) "after Reset-PkAbortState the next run is normal again"

# Your own long step inside Invoke-PkRun has to poll.
Reset-Harness
$own = @{ Steps = 0 }
Invoke-PkRun -ScriptBlock {
    for ($i = 0; $i -lt 1000; $i++) {
        if ($i -eq 3) { Request-PkAbort }
        if (Test-PkAbortSignal) { break }
        $own.Steps++
    }
}.GetNewClosure()
Test-Assert ($own.Steps -eq 3) "your own loop inside Invoke-PkRun can stop on an abort by polling Test-PkAbortSignal"
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Abort requested*' }).Count -eq 1) "and the abort is announced once"

# QuickEdit is put back the way it was found.
Reset-Harness
$quickEditBefore = [PkConsoleQuickEdit]::GetEnabled()
Invoke-PkRun -ScriptBlock { }
Test-Assert ($quickEditBefore -in @(-1, 0, 1) -and [PkConsoleQuickEdit]::GetEnabled() -eq $quickEditBefore) ("QuickEdit is left as it was found after a run (state " + $quickEditBefore + ")")
if ($quickEditBefore -eq 1) {
    $null = [PkConsoleQuickEdit]::SetEnabled($false)
    Invoke-PkRun -ScriptBlock { }
    Test-Assert ([PkConsoleQuickEdit]::GetEnabled() -eq 0) "a console that had QuickEdit off still has it off after a run"
    $null = [PkConsoleQuickEdit]::SetEnabled($true)
}
Write-Host ""

# ==============================================================================
Write-Host "=== P: edge cases - delegate detection, self-setup, careless callbacks ===" -ForegroundColor Cyan
Reset-Harness

# The safety check sees scriptblocks handed straight to .NET.
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $d = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new(); $null = $d.GetOrAdd('a', { 1 }) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock passed straight to a .NET method is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $lazy = [System.Lazy[object]]::new({ 1 }) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock passed to a .NET constructor is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $x = @(1, 2).ForEach({ $_ }); $y = @(1, 2).Where({ $_ }); $z = { 1 }.GetNewClosure() }
Test-Assert ($f.Count -eq 0) "PowerShell's own .ForEach()/.Where()/.GetNewClosure() are not flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $factory = { 1 }; $lazy = [System.Lazy[object]]::new($factory) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast' -and $f[0].Text -like '*$factory*') "a variable holding a scriptblock, passed to a .NET constructor, is flagged by name"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $add = { param($k, $old) $old + 1 }.GetNewClosure(); $d = [System.Collections.Concurrent.ConcurrentDictionary[string,int]]::new(); $null = $d.AddOrUpdate('a', 1, $add) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a variable holding a .GetNewClosure() block, passed to a .NET method, is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $sb = { $_ * 2 }; $n = 'x'; $x = @(1, 2).ForEach($sb); $null = $n.Contains($n) }
Test-Assert ($f.Count -eq 0) "a scriptblock variable given to .ForEach(), and other variables given to .NET methods, are not flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $null = [System.Threading.Tasks.Task]::Run({ 1 })  # pk:ignore
}
Test-Assert ($f.Count -eq 0) "'# pk:ignore' accepts a finding on its line"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $h = { 1 }; $m = [System.Collections.Generic.Dictionary[string,scriptblock]]::new(); $m.Add('a', $h); $l = [System.Collections.Generic.List[scriptblock]]::new(); $l.Add({ 2 }); $q = [System.Collections.Generic.Queue[scriptblock]]::new(); $q.Enqueue($h) }
Test-Assert ($f.Count -eq 0) ("storing a scriptblock in a collection (.Add/.Enqueue) is not flagged (got " + $f.Count + ")")
$f = Test-PkWorkerSafety -WorkerScript { param($Id) $h = { 1 }; $d = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new(); $null = $d.GetOrAdd('a', $h) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'DelegateCast') "a scriptblock variable passed as a GetOrAdd factory is still flagged"

# MissingFunction through an alias, and for a module a worker can't load.
Set-Alias -Name hdbl -Value Get-HarnessDouble -Scope Global
$f = Test-PkWorkerSafety -WorkerScript { param($Id) hdbl -Value $Id }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'MissingFunction') "an alias to an unshared function of yours is flagged"
Remove-Item -LiteralPath Alias:\hdbl
$modName = "pk-temp-" + [guid]::NewGuid().ToString("N")
$modPath = Join-Path $env:TEMP ($modName + ".psm1")
[System.IO.File]::WriteAllText($modPath, 'function Get-PkTempModuleThing { 1 }')
Import-Module -Name $modPath -Global
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-PkTempModuleThing }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'MissingFunction' -and $f[0].Text -like '*PSModulePath*') "a function from a module imported by path is flagged"
$f = Test-PkWorkerSafety -WorkerScript { param($Id) Get-PkTempModuleThing } -SharedFunctionNames @('Get-PkTempModuleThing')
Test-Assert ($f.Count -eq 0) "and listing it in -SharedFunctionNames clears it"
Remove-Module -Name $modName
[System.IO.File]::Delete($modPath)

# Job-value scan: nested values, typed arrays, and live shared collections.
$mainThreadBlock = { 1 }
Test-Assert ((& (Get-Module ParallelKit) Get-PkScriptBlockJobKey -Job @{ Steps = @(@{ Name = 'a'; Run = $mainThreadBlock }) }) -eq 'Steps') "a scriptblock two levels down in a job value is found"
Test-Assert ((& (Get-Module ParallelKit) Get-PkScriptBlockJobKey -Job @{ Opts = [pscustomobject]@{ OnDone = $mainThreadBlock } }) -eq 'Opts') "a scriptblock in a [pscustomobject] property is found"
$bigBytes = [byte[]]::new(20MB)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$key = & (Get-Module ParallelKit) Get-PkScriptBlockJobKey -Job @{ Data = $bigBytes; Paths = [string[]]::new(200000) }
$sw.Stop()
Test-Assert ($null -eq $key -and $sw.Elapsed.TotalSeconds -lt 1) ("a 20 MB byte[] and a 200k string[] are skipped, not walked (" + [int]$sw.Elapsed.TotalMilliseconds + "ms)")
$sink = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
for ($i = 0; $i -lt 20000; $i++) { $null = $sink.Add([pscustomobject]@{ N = $i }) }
$writer = [PowerShell]::Create()
$null = $writer.AddScript('param($s) while ($true) { $null = $s.Add(1); $s.RemoveAt(0) }').AddArgument($sink)
$writerHandle = $writer.BeginInvoke()
$scanError = $null
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 3 -and $null -eq $scanError) {
    try { $null = & (Get-Module ParallelKit) Get-PkScriptBlockJobKey -Job @{ Sink = $sink } } catch { $scanError = $_ }
}
$null = $writer.BeginStop($null, $null)
$writer.Dispose()
Test-Assert ($null -eq $scanError) ("scanning a collection other threads are changing doesn't throw (" + $scanError + ")")

# With no Initialize-ParallelKit at all, starting a process sets up the
# thread pool and the kill-on-close job object. Needs a fresh process.
$probeScript = Join-Path $env:TEMP ("pk-probe-" + [guid]::NewGuid().ToString("N") + ".ps1")
$kitPath = Join-Path $PSScriptRoot "ParallelKit.ps1"
[System.IO.File]::WriteAllText($probeScript, @"
. '$kitPath'
`$before = [PkChildProcessJob]::IsInitialized
`$j = Start-PkProcess -FilePath '$cmdExe' -Arguments '/c exit 0'
`$null = Wait-PkProcess -Process `$j.Proc -TimeoutMs 5000
`$w = 0; `$io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]`$w, [ref]`$io)
Write-Output ("before=" + `$before + " after=" + [PkChildProcessJob]::IsInitialized + " threads=" + `$w)
"@)
$probe = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $probeScript + '"') -TimeoutMs 60000
[System.IO.File]::Delete($probeScript)
Test-Assert ($probe.Stdout -match 'before=False after=True') ("starting a process sets up child cleanup by itself (" + ([string]$probe.Stdout).Trim() + ")")
$probeThreads = 0
if ($probe.Stdout -match 'threads=(\d+)') { $probeThreads = [int]$Matches[1] }
Test-Assert ($probeThreads -ge 128) ("and raises the thread pool by itself (minimum " + $probeThreads + ")")

# A script run the way a prompt runs it (& script, or .\script.ps1) holds
# the kit's functions in its own scope, where a .GetNewClosure() block can't
# see them. The kit's public functions are imported globally, so the batch (whose callbacks are
# closures) and a caller's closure that calls a kit function both work.
# Needs a fresh process, started with -Command rather than -File.
$promptScript = Join-Path $env:TEMP ("pk-prompt-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($promptScript, @"
. '$kitPath'
`$b = Invoke-PkProcessBatch -Commands @(@{ FilePath = '$cmdExe'; Arguments = '/c exit 7' })
Write-Output ('batch=' + `$b.Results.Count + ',' + `$b.Results[0].ExitCode)
`$tag = 'ok'
`$closure = Invoke-PkRun { Test-PkCancelRequested | Out-Null; 'closure=' + `$tag }.GetNewClosure()
Write-Output `$closure
"@)
$prompt = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments (ConvertTo-PkArgumentString @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ("& '" + $promptScript + "'"))) -TimeoutMs 60000
[System.IO.File]::Delete($promptScript)
Test-Assert ($prompt.Stdout -match 'batch=1,7') ("a batch works in a script run from a prompt (" + ([string]$prompt.Stdout + [string]$prompt.Stderr).Trim() + ")")
Test-Assert ($prompt.Stdout -match 'closure=ok') "and so does a .GetNewClosure() block that calls a kit function"
# Pasted into a larger script under strict mode, only the kit's functions
# are made global: the script's own (here one defined after the kit, and
# one before) are left alone, and loading raises no errors.
$embedScript = Join-Path $env:TEMP ("pk-embed-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($embedScript, "Set-StrictMode -Version Latest`r`n`$ErrorActionPreference = 'Stop'`r`nfunction Get-HarnessBefore { 1 }`r`n`$fnAst = 'mine'`r`n" +
    [System.IO.File]::ReadAllText($kitPath) +
    "`r`nfunction Get-HarnessAfter { 2 }`r`nWrite-Output ('kitGlobal=' + [bool](Get-ChildItem Function: | Where-Object { `$_.Name -eq 'Start-PkProcess' }))`r`nWrite-Output ('caller var=' + `$fnAst)`r`n")
$embed = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments (ConvertTo-PkArgumentString @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ("& '" + $embedScript + "'; 'before global=' + [bool](Get-Command Get-HarnessBefore -ErrorAction SilentlyContinue); 'after global=' + [bool](Get-Command Get-HarnessAfter -ErrorAction SilentlyContinue); 'kit global=' + [bool](Get-Command Start-PkProcess -ErrorAction SilentlyContinue)"))) -TimeoutMs 60000
[System.IO.File]::Delete($embedScript)
$embedOut = ([string]$embed.Stdout + [string]$embed.Stderr).Trim()
Test-Assert ($embedOut -match 'kit global=True' -and $embedOut -match 'before global=False' -and $embedOut -match 'after global=False' -and $embedOut -match 'caller var=mine' -and [string]::IsNullOrWhiteSpace([string]$embed.Stderr)) ("pasted into a larger script, only the kit's functions are made global, without errors or touching the script's variables (" + ($embedOut -replace '\s+', ' ') + ")")

# Loading the kit in Constrained Language Mode fails with a message that
# says so. Needs a fresh process: the mode can't be set back.
$clmScript = Join-Path $env:TEMP ("pk-clm-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($clmScript, @"
`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
try { . '$kitPath'; Write-Output 'loaded' } catch { Write-Output ('error: ' + `$_) }
"@)
$clm = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $clmScript + '"') -TimeoutMs 60000
[System.IO.File]::Delete($clmScript)
Test-Assert ($clm.Stdout -like '*ConstrainedLanguage mode, but the kit needs FullLanguage*') ("loading in Constrained Language Mode fails with a message naming the problem (" + ([string]$clm.Stdout).Trim() + ")")

# The dispatcher sizes the pool for its own concurrency.
$feed = @{ Given = $false }
$null = Invoke-PkProcessDispatch -MaxConcurrent 100 -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) }
$w = 0; $io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
Test-Assert ($w -ge 232) ("the dispatcher raises the thread pool to fit -MaxConcurrent (minimum " + $w + " for 100 processes)")

# A one-line starter keeps the caller's job fields.
Reset-Harness
$feed = @{ Given = $false }
$seenTags = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 's' } }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0'; Tag = 'first' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0'; Tag = 'second' }) }.GetNewClosure() `
    -JobStarter { param($job) Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments } `
    -JobFinalize { param($job, $pending) $r = Complete-PkProcess -Job $job; $seenTags.Add($job.Tag) }.GetNewClosure()
Test-Assert ($seenTags.Count -eq 2 -and ($seenTags -contains 'first') -and ($seenTags -contains 'second')) "a starter that is just 'Start-PkProcess ...' keeps the job's own fields for JobFinalize"
Test-Assert ($d.JobStarterFailedCount -eq 0 -and $d.GroupResults.Count -eq 1) "and the jobs run and complete normally"

# A message handler that throws.
Reset-Harness
Set-PkMessageHandler -Handler { param($Message, $Level) throw "log file locked" }
$results = [System.Collections.Generic.List[object]]::new()
$threw = $false
try {
    $out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })) `
        -WorkerScript { param([int]$Id) Write-PkMessage ("from " + $Id); if ($Id -eq 2) { throw "boom" }; return $Id } `
        -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
} catch { $threw = $true }
Set-PkMessageHandler -Handler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()
Test-Assert (-not $threw -and $out.CrashedCount -eq 1 -and $results.Count -eq 2) "a message handler that throws doesn't take the run down"

# Stray output from a builder and from a provider.
Reset-Harness
$feed = @{ Given = $false }
$done = @{ Jobs = 0 }
$seenGroups = [System.Collections.Generic.HashSet[string]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'b' } }.GetNewClosure() `
    -JobBuilder { param($g) $seenGroups.Add($g.Name); "noise"; return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++ }.GetNewClosure()
Test-Assert ($done.Jobs -eq 1 -and $d.GroupResults.Count -eq 1) "a job builder that lets stray output escape still gets its job run"
Test-Assert (@($script:messages | Where-Object { $_.Level -eq 'Warn' -and $_.Message -like '*-JobBuilder returned 2 value(s)*' }).Count -eq 1) "and the ignored values are reported"

Reset-Harness
$feed = @{ Next = 1 }
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -WorkerScript { param([int]$Id) return $Id } `
    -NextJobProvider { if ($feed.Next -gt 3) { return $null }; "noise"; $j = @{ Id = $feed.Next }; $feed.Next++; return $j }.GetNewClosure() `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 3 -and $out.CrashedCount -eq 0) "a job provider that lets stray output escape still feeds its jobs"

# Working directory on the single-process helper.
$wdResult = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory $env:SystemRoot
Test-Assert ($wdResult.Stdout.Trim() -ieq $env:SystemRoot) "Invoke-PkProcessWithTimeout honors -WorkingDirectory"

# A bad key in a fixed job list is caught before anything runs.
Reset-Harness
$ran = @{ Count = 0 }
$gate = [object]::new()
$threw = $false
try {
    $null = Invoke-PkRunspaceJobs -MaxParallel 1 `
        -JobParams (New-JobList -Jobs @(@{ Id = 1; Ran = $ran; Gate = $gate }, @{ Id = 2; Ran = $ran; Gate = $gate }, @{ Id = 3; Ran = $ran; Gate = $gate; Typo = 1 })) `
        -WorkerScript { param([int]$Id, $Ran, $Gate) [System.Threading.Monitor]::Enter($Gate); try { $Ran.Count++ } finally { [System.Threading.Monitor]::Exit($Gate) }; return $Id }
} catch { $threw = ($_.ToString() -like "*job 2 supplies 'Typo'*Nothing was started*") }
[System.Threading.Thread]::Sleep(300)
Test-Assert ($threw -and $ran.Count -eq 0) ("a bad key in -JobParams is reported before any worker starts (workers run: " + $ran.Count + ")")

# A callback built without .GetNewClosure() must add to the caller's
# $results, not to a collection of the kit's: if it were the one the kit
# loops over, the loop would never end. The guard throws instead of hanging.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$loopGuard = @{ Calls = 0 }
$threw = $null
try {
    $null = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 })) -WorkerScript { param([int]$Id) $Id } -ResultHandler {
        param($r)
        $loopGuard.Calls++
        if ($loopGuard.Calls -gt 20) { throw 'still looping after 20 handler calls' }
        $results.Add($r)
    }
} catch { $threw = $_.Exception.Message }
Test-Assert ($null -eq $threw -and $loopGuard.Calls -eq 2 -and $results.Count -eq 2) ("a -ResultHandler without a closure: `$results.Add reaches the caller's list and doesn't loop (calls=" + $loopGuard.Calls + ", count=" + $results.Count + ", threw=" + $threw + ")")

# The same on the abort-drain path, which collects results separately.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$loopGuard = @{ Calls = 0 }
$poll = @{ Count = 0 }
$threw = $null
try {
    $null = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })) -WorkerScript {
        param([int]$Id)
        # Finish only after the abort, and late enough that the main loop has
        # already handed over to the drain.
        for ($i = 0; $i -lt 100; $i++) { if (Test-PkCancelRequested) { break }; [System.Threading.Thread]::Sleep(50) }
        [System.Threading.Thread]::Sleep(500)
        return $Id
    } -PollCallback { $poll.Count++; if ($poll.Count -eq 3) { Request-PkAbort } }.GetNewClosure() -ResultHandler {
        param($r)
        $loopGuard.Calls++
        if ($loopGuard.Calls -gt 20) { throw 'still looping after 20 handler calls' }
        $results.Add($r)
    }
} catch { $threw = $_.Exception.Message }
# The wait message only appears when the drain had running jobs to collect,
# so this also proves the results came through the drain, not the main loop.
$drained = @($script:messages | Where-Object { $_.Message -like '*Waiting for current jobs*' }).Count -eq 1
Test-Assert ($null -eq $threw -and $loopGuard.Calls -eq 2 -and $results.Count -eq 2 -and $drained) ("a -ResultHandler without a closure doesn't loop during an abort drain either (calls=" + $loopGuard.Calls + ", count=" + $results.Count + ", drained=" + $drained + ", threw=" + $threw + ")")

# A -JobCrashedHandler without a closure sees the caller's $results.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -WorkerScript { param([int]$Id) throw "x" } -JobCrashedHandler { param($e) $results.Add($e) }
Test-Assert ($results.Count -eq 1) ("a -JobCrashedHandler without a closure reaches the caller's `$results (count=" + $results.Count + ")")
Reset-Harness
Write-Host ""

# ==============================================================================
Write-Host "=== Q: edge cases - follow-up jobs, re-queued jobs, -JobParams shapes ===" -ForegroundColor Cyan

# The dispatcher counts what JobFinalize queued, not what it returns: a
# return value claiming a requeue, with nothing queued, must not hang the group.
Reset-Harness
$done = @{ Groups = 0; Jobs = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-HarnessOneGroupDispatch -Done $done -JobStarter $null -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $done.Jobs++; return @{ Requeued = $true } }.GetNewClosure()
$sw.Stop()
Test-Assert ($done.Groups -eq 1 -and $sw.Elapsed.TotalSeconds -lt 10) "a JobFinalize return value is ignored - claiming a requeue with nothing queued doesn't hang the dispatcher"

# Two follow-up jobs, no flag: the group completes only after ALL of them.
Reset-Harness
$feed = @{ Given = $false }
$order = [System.Collections.Generic.List[string]]::new()
$state = @{ Split = $false }
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'split' } }.GetNewClosure() `
    -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $null = Complete-PkProcess -Job $job
        $order.Add('job')
        if (-not $state.Split) {
            $state.Split = $true
            $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })
            $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })
        }
    }.GetNewClosure() `
    -GroupCompleteCallback { param($group) $order.Add('group') }.GetNewClosure()
Test-Assert (($order -join ',') -eq 'job,job,job,group') ("a group whose job queues two follow-ups completes only after both finish (order: " + ($order -join ',') + ")")

# The same job object put back on the queue, with a one-line starter.
Reset-Harness
$feed = @{ Given = $false }
$state = @{ Retried = $false; Finalized = 0 }
$threw = $false
try {
    $d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 're' } }.GetNewClosure() `
        -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0'; Tag = 'keep' } }.GetNewClosure() `
        -JobStarter { param($job) Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments } `
        -JobFinalize {
            param($job, $pending)
            $null = Complete-PkProcess -Job $job
            $state.Finalized++
            if (-not $state.Retried) { $state.Retried = $true; $pending.Enqueue($job) }
        }.GetNewClosure()
} catch { $threw = $true }
Test-Assert (-not $threw -and $state.Finalized -eq 2 -and $d.GroupResults.Count -eq 1) "putting the SAME job object back on the queue runs it again cleanly"

# -JobParams: one bare hashtable, a plain array, and a bad entry.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$oneJob = foreach ($n in @(7)) { @{ Id = $n } }
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams $oneJob -WorkerScript { param([int]$Id) return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 1 -and $results[0] -eq 7) "-JobParams accepts a job list that collapsed to a single hashtable"
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -WorkerScript { param([int]$Id) return $Id } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($results.Count -eq 2) "-JobParams accepts a plain array of hashtables"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Id = 1 }, 'oops') -WorkerScript { param($Id) } } catch { $threw = ($_.ToString() -like '*entry 1 is not a hashtable*') }
Test-Assert $threw "-JobParams with a non-hashtable entry fails with a message naming the entry"
$threw = $false
try { $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Id = 1 }, $null) -WorkerScript { param($Id) } } catch { $threw = ($_.ToString() -like '*entry 1 is not a hashtable*') }
Test-Assert $threw "-JobParams with a `$null entry fails the same way"

# A shared budget sizes the thread pool too.
$bigBudget = [System.Threading.SemaphoreSlim]::new(150, 150)
$null = Invoke-PkProcessDispatch -MaxConcurrent $bigBudget -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) }
$w = 0; $io = 0
[System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
Test-Assert ($w -ge 332) ("a shared budget of 150 raises the thread pool to fit (minimum " + $w + ")")
$bigBudget.Dispose()
Write-Host ""

# ==============================================================================
Write-Host "=== R: edge cases - group identity, .Group, large batches ===" -ForegroundColor Cyan

# Two groups that compare equal keep separate job counts.
Reset-Harness
$feed = @{ Index = 0 }
$order = [System.Collections.Generic.List[string]]::new()
$groupsSeen = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 -MaxQueueAhead 2 `
    -GroupProvider { if ($feed.Index -ge 2) { return $null }; $feed.Index++; return 'Group 1' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $order.Add('job'); $groupsSeen.Add($job.Group) }.GetNewClosure() `
    -GroupCompleteCallback { param($group) $order.Add('group') }.GetNewClosure()
Test-Assert (($order -join ',') -eq 'job,job,group,job,job,group') ("two groups with the same name each complete after their own two jobs (order: " + ($order -join ',') + ")")
Test-Assert ($d.GroupResults.Count -eq 2) "and both are reported"
Test-Assert ($groupsSeen.Count -eq 4 -and @($groupsSeen | Where-Object { $_ -ne 'Group 1' }).Count -eq 0) "each job carries its group value as .Group"

# A follow-up job inherits .Group as well as its place in the group.
Reset-Harness
$feed = @{ Given = $false }
$state = @{ Split = $false }
$groupsSeen = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'only' }.GetNewClosure() `
    -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $null = Complete-PkProcess -Job $job
        $groupsSeen.Add($job.Group)
        if (-not $state.Split) { $state.Split = $true; $pending.Enqueue(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }
    }.GetNewClosure()
Test-Assert ($groupsSeen.Count -eq 2 -and $groupsSeen[1] -eq 'only') "a follow-up job gets its group's .Group too"

# A re-run job gets a fresh stopwatch.
Reset-Harness
$feed = @{ Given = $false }
$state = @{ Retried = $false }
$watches = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'sw' } }.GetNewClosure() `
    -JobBuilder { param($g) return @{ FilePath = $cmdExe; Arguments = '/c exit 0' } }.GetNewClosure() `
    -JobStarter { param($job) Start-PkProcess -FilePath $job.FilePath -Arguments $job.Arguments } `
    -JobFinalize {
        param($job, $pending)
        $null = Complete-PkProcess -Job $job
        $watches.Add($job.Stopwatch)
        if (-not $state.Retried) { $state.Retried = $true; $pending.Enqueue($job) }
    }.GetNewClosure()
Test-Assert ($watches.Count -eq 2 -and $null -ne $watches[1] -and -not [object]::ReferenceEquals($watches[0], $watches[1])) "a job that goes around again gets a fresh stopwatch"

# A large batch isn't slowed by per-job queue walks. No processes: the
# starter/poll are stubs, so this times the dispatcher's own bookkeeping.
Reset-Harness
$bigCount = 20000
$feed = @{ Given = $false }
$done = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$d = Invoke-PkProcessDispatch -MaxConcurrent 1000 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return @{ Name = 'big' } }.GetNewClosure() `
    -JobBuilder { param($g) $jobs = [System.Collections.Generic.List[hashtable]]::new(); for ($i = 0; $i -lt $bigCount; $i++) { $jobs.Add(@{ Id = $i }) }; return $jobs }.GetNewClosure() `
    -JobStarter { param($job) return $job } -JobPollCompleted { param($job) return $true } `
    -JobFinalize { param($job, $pending) $done.Count++ }.GetNewClosure()
$sw.Stop()
Test-Assert ($done.Count -eq $bigCount) "a 20,000-job group runs to completion"
Test-Assert ($sw.Elapsed.TotalSeconds -lt 15) ("and the dispatcher's own bookkeeping stays quick (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s for 20,000 jobs)")
Write-Host ""

# ==============================================================================
Write-Host "=== S: edge cases - abort timing, strict mode, stale types, sleep, -IgnoreAbort ===" -ForegroundColor Cyan

# Invoke-PkProcessWithTimeout stops promptly on an abort. The abort is
# raised from another thread while the main thread is inside the wait.
Reset-Harness
$abortTimer = [PowerShell]::Create()
$null = $abortTimer.AddScript({ [System.Threading.Thread]::Sleep(700); [PkConsoleCtrl]::AbortRequested = $true })
$abortTimerHandle = $abortTimer.BeginInvoke()
$threw = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 25000 } catch { $threw = ($_.ToString() -like '*being aborted*') }
$sw.Stop()
Test-Assert ($threw -and $sw.Elapsed.TotalSeconds -lt 6) ("Invoke-PkProcessWithTimeout stops its program when the run is aborted (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s, time limit was 25s)")
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*Abort requested*' }).Count -eq 1) "and the abort is announced"
$null = $abortTimer.EndInvoke($abortTimerHandle); $abortTimer.Dispose()

# A window close gets no drain, so its announcement mustn't say it waits.
Reset-Harness
[PkConsoleCtrl]::IsCloseEvent = $true
[PkConsoleCtrl]::AbortRequested = $true
$null = Test-PkAbortSignal
$closeMessage = @($script:messages | Where-Object { $_.Message -like '*Window close detected*' })
Test-Assert ($closeMessage.Count -eq 1 -and $closeMessage[0].Message -notlike '*please wait*' -and $closeMessage[0].Message -like '*stopping*') ("a window close is announced as stopping jobs, not waiting for them (" + (@($closeMessage | ForEach-Object { $_.Message }) -join ' | ') + ")")
Reset-PkAbortState

# The same from inside a worker, where the run's cancel is what it sees.
Reset-Harness
$poll = @{ Count = 0 }
$workerErrors = [System.Collections.Generic.List[object]]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @{ PingExe = $pingExe } -DrainTimeoutSeconds 20 `
    -WorkerScript { param($PingExe) try { $null = Invoke-PkProcessWithTimeout -FilePath $PingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 25000; return 'finished' } catch { return [string]$_ } } `
    -ResultHandler { param($r) $workerErrors.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 6) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($workerErrors.Count -eq 1 -and $workerErrors[0] -like '*being aborted*' -and $sw.Elapsed.TotalSeconds -lt 8 -and $out.ForceStoppedCount -eq 0) ("inside a worker it stops on the run's abort too (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s)")

Reset-Harness
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$threw = $false
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 30 127.0.0.1' -TimeoutMs 900 } catch { $threw = ($_.ToString() -like '*did not exit within 900ms*') }
Test-Assert ($threw -and $sw.Elapsed.TotalSeconds -lt 5) "the plain time limit still works and reports itself as a timeout"
$quick = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c exit 9'
Test-Assert ($quick.ExitCode -eq 9) "and a program that finishes in time is returned normally"

# Reset-PkAbortState part-way through a run leaves the run armed.
Reset-Harness
$mid = @{ ArmedAfterReset = $false; AbortCleared = $false; SecondPhase = 0 }
Invoke-PkRun -ScriptBlock {
    Request-PkAbort
    $null = Test-PkAbortSignal
    Reset-PkAbortState
    $mid.ArmedAfterReset = [PkConsoleCtrl]::RunActive
    $mid.AbortCleared    = -not (Test-PkAbortSignal)
    $second = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 1
    if (-not $second.Aborted) { $mid.SecondPhase = $second.Results.Count }
}.GetNewClosure()
Test-Assert ($mid.ArmedAfterReset -eq $true) "Reset-PkAbortState inside a run leaves Ctrl+C handling armed"
Test-Assert ($mid.AbortCleared -and $mid.SecondPhase -eq 1) "and the next phase of that run then works normally"
Test-Assert ([PkConsoleCtrl]::RunActive -eq $false) "the run still disarms at its own end"

# A worker that turns strict mode on can still use the kit's functions.
Reset-Harness
$results = [System.Collections.Generic.List[object]]::new()
$out = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @{ CmdExe = $cmdExe } `
    -WorkerScript {
        param($CmdExe)
        Set-StrictMode -Version Latest   # pk:ignore
        $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $CmdExe; Arguments = '/c exit 0' }, @{ FilePath = 'C:\no\such\program.exe' }) -MaxConcurrent 2
        $single = Invoke-PkProcessWithTimeout -FilePath $CmdExe -Arguments '/c exit 6'
        Write-PkMessage "strict worker done"
        return ("results=" + $batch.Results.Count + " exit=" + $single.ExitCode)
    } -ResultHandler { param($r) $results.Add($r) }.GetNewClosure()
Test-Assert ($out.CrashedCount -eq 0 -and $results.Count -eq 1 -and $results[0] -eq 'results=2 exit=6') ("the kit's process functions work inside a worker that runs under strict mode (" + ($results -join '') + ")")

# Loading the kit into a session that holds an older copy's compiled types
# says so clearly. Needs a fresh process with stand-in "old" types.
$staleScript = Join-Path $env:TEMP ("pk-stale-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($staleScript, @"
Add-Type -TypeDefinition 'public static class PkConsoleCtrl { } public static class PkState { }'
try { . '$kitPath'; Write-Output 'LOADED' } catch { Write-Output ('REFUSED: ' + `$_) }
"@)
$stale = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments ('-NoProfile -ExecutionPolicy Bypass -File "' + $staleScript + '"') -TimeoutMs 60000
[System.IO.File]::Delete($staleScript)
Test-Assert ($stale.Stdout -like '*REFUSED:*older version of the kit*start a new one*') "loading the kit over an older copy's types is refused with a clear message"

# Invoke-PkRun keeps the PC from idle-sleeping only while it runs. Checked
# on this thread: SetThreadExecutionState returns the thread's previous
# state. The system-wide flag says nothing, since other programs may hold it.
if (-not ([System.Management.Automation.PSTypeName]'PkThreadStateProbe').Type) {
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class PkThreadStateProbe { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f); }'
}
$esContinuous = [uint32]2147483648
$esKeepAwake  = [uint32]2147483649
Reset-Harness
$awakeDuring = Invoke-PkRun -ScriptBlock { return [PkThreadStateProbe]::SetThreadExecutionState($esKeepAwake) }.GetNewClosure()
$awakeAfter  = [PkThreadStateProbe]::SetThreadExecutionState($esContinuous)
Test-Assert ($awakeDuring -eq $esKeepAwake -and $awakeAfter -eq $esContinuous) ("Invoke-PkRun blocks idle sleep during the run and lifts it afterwards (during 0x" + ([uint32]$awakeDuring).ToString("X8") + ", after 0x" + ([uint32]$awakeAfter).ToString("X8") + ")")
$awakeOptOut = Invoke-PkRun -KeepAwake $false -ScriptBlock { return [PkThreadStateProbe]::SetThreadExecutionState($esContinuous) }.GetNewClosure()
Test-Assert ($awakeOptOut -eq $esContinuous) "-KeepAwake `$false leaves sleep alone"

# Cleanup programs can still be run while an abort is in force.
Reset-Harness
Request-PkAbort
$null = Test-PkAbortSignal
$threw = $false
try { $null = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 3 127.0.0.1' } catch { $threw = ($_.ToString() -like '*being aborted*') }
Test-Assert $threw "while an abort is in force, the helper stops a program by default"
$cleanup = $null
try { $cleanup = Invoke-PkProcessWithTimeout -FilePath $pingExe -Arguments '-n 3 127.0.0.1' -IgnoreAbort } catch { }
Test-Assert ($null -ne $cleanup -and $cleanup.ExitCode -eq 0) "-IgnoreAbort lets a cleanup program run to the end during an abort"

# A job's own Group field is left alone.
Reset-Harness
$feed = @{ Given = $false }
$groupsSeen = [System.Collections.Generic.List[object]]::new()
$d = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'the-group' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0'; Group = 'mine' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job; $groupsSeen.Add($job.Group) }.GetNewClosure()
Test-Assert ($groupsSeen.Count -eq 2 -and ($groupsSeen -contains 'mine') -and ($groupsSeen -contains 'the-group')) "a job's own Group field is kept; a job without one gets the group"

# The safety check looks inside functions defined in the worker script.
$f = Test-PkWorkerSafety -WorkerScript { param($Id) function Get-Inner { return $script:cache }; $script:top = 1; return (Get-Inner) }
Test-Assert ($f.Count -eq 1 -and $f[0].Rule -eq 'ScriptVariable') "`$script: inside a function defined in the worker script is flagged (the worker's own top level still isn't)"
Write-Host ""

# ==============================================================================
Write-Host "=== T: edge cases - tokens in workers, batch result fields, aborted groups ===" -ForegroundColor Cyan
Reset-Harness
# A dispatcher inside a worker, given a token of the worker's own making,
# must still stop on an abort - not run its processes to the end.
$ownTokenEngine = {
    param([string]$PingExe)
    $mineInWorker = [System.Threading.CancellationTokenSource]::new()
    $feed = @{ Given = $false }
    $d = Invoke-PkProcessDispatch -MaxConcurrent 1 -AbortTimeoutSeconds 1 -CancelToken $mineInWorker.Token `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $PingExe; Arguments = '-n 30 127.0.0.1' }, @{ FilePath = $PingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
        -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job }
    return @{ Aborted = $d.Aborted; OwnCanceled = $mineInWorker.IsCancellationRequested }
}
$results = [System.Collections.Generic.List[hashtable]]::new()
$poll = @{ Count = 0 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PkRunspaceJobs -WorkerScript $ownTokenEngine -JobParams @{ PingExe = $pingExe } -MaxParallel 1 -DrainTimeoutSeconds 20 `
    -ResultHandler { param($r) $results.Add($r) }.GetNewClosure() `
    -PollCallback { $poll.Count++; if ($poll.Count -eq 15) { Request-PkAbort } }.GetNewClosure()
$sw.Stop()
Test-Assert ($out.ForceStoppedCount -eq 0 -and $results.Count -eq 1 -and $results[0].Aborted) ("a dispatcher in a worker with its own -CancelToken stops on an abort (force-stopped " + $out.ForceStoppedCount + ", " + [int]$sw.Elapsed.TotalSeconds + "s)")
Test-Assert ($results.Count -eq 1 -and -not $results[0].OwnCanceled) "without canceling the worker's own token"
Test-Assert ([PkState]::SourceCount -eq 0) "and nothing is left registered"

# Every batch result has every documented field, so a strict-mode caller
# can read any of them without a "property cannot be found" error.
Reset-Harness
# Results are objects with their fields in a fixed order, so Format-Table
# shows them readably.
function Get-HarnessShape($o) { if ($o -isnot [System.Management.Automation.PSCustomObject]) { return '(not an object)' }; return ($o.PSObject.Properties.Name -join ',') }
$shapeBatch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' })
Test-Assert ((Get-HarnessShape $shapeBatch) -eq 'Results,Aborted,ForceKilledCount') ("a batch returns an object (" + (Get-HarnessShape $shapeBatch) + ")")
Test-Assert ((Get-HarnessShape $shapeBatch.Results[0]) -eq 'Command,ExitCode,Stdout,Stderr,StreamTimedOut,StreamError,StartError,Aborted,TimedOut') ("each batch result is an object, fields in order (" + (Get-HarnessShape $shapeBatch.Results[0]) + ")")
$shapeOne = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c exit 0'
Test-Assert ((Get-HarnessShape $shapeOne) -eq 'ExitCode,Stdout,Stderr,StreamTimedOut,StreamError') ("Invoke-PkProcessWithTimeout returns an object (" + (Get-HarnessShape $shapeOne) + ")")
$shapeDispatch = Invoke-PkProcessDispatch -MaxConcurrent 1 -GroupProvider { return $null } -JobBuilder { param($g) } -JobFinalize { param($j, $p) }
Test-Assert ((Get-HarnessShape $shapeDispatch) -eq 'GroupResults,Aborted,ForceKilledCount,JobStarterFailedCount') ("the dispatcher returns an object (" + (Get-HarnessShape $shapeDispatch) + ")")
$shapeJobs = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @{ Id = 1 } -WorkerScript { param($Id) }
Test-Assert ((Get-HarnessShape $shapeJobs) -eq 'ForceStoppedCount,CrashedCount,Aborted,Crashed,Errors') ("runspace jobs return an object (" + (Get-HarnessShape $shapeJobs) + ")")
$shapeFindings = Test-PkWorkerSafety -WorkerScript { param($Id) $null = [Func[int]]{ 1 } }
$shapeFinding = $shapeFindings[0]
Test-Assert ((Get-HarnessShape $shapeFinding) -eq 'Rule,Where,Line,Text') ("worker-safety findings are objects (" + (Get-HarnessShape $shapeFinding) + ")")
Test-Assert ((Get-HarnessShape (Initialize-ParallelKit)) -eq 'AbortHandler,ChildProcessJob,ThreadPool') "Initialize-ParallelKit returns an object"

$fields = @('Command', 'ExitCode', 'Stdout', 'Stderr', 'StreamTimedOut', 'StreamError', 'StartError', 'Aborted', 'TimedOut')
$batch = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(
    @{ FilePath = $cmdExe; Arguments = '/c exit 0' },
    @{ FilePath = 'C:\definitely\not\here.exe' })
$missing = foreach ($r in $batch.Results) { foreach ($k in $fields) { if ($r.PSObject.Properties.Name -notcontains $k) { $k } } }
Test-Assert ($batch.Results.Count -eq 2 -and @($missing).Count -eq 0) ("batch results for a finished and an unstartable command carry every field (missing: " + (@($missing) -join ', ') + ")")

# An abort already in force: nothing starts, every command comes back Aborted.
Reset-Harness
Request-PkAbort
$batch = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' })
$missing = foreach ($r in $batch.Results) { foreach ($k in $fields) { if ($r.PSObject.Properties.Name -notcontains $k) { $k } } }
Test-Assert ($batch.Aborted -and $batch.Results.Count -eq 2 -and @($batch.Results | Where-Object { $_.Aborted }).Count -eq 2) "batch: commands an abort kept from starting come back marked Aborted"
Test-Assert (@($missing).Count -eq 0) ("and their results carry every field too (missing: " + (@($missing) -join ', ') + ")")
Reset-PkAbortState

# -TimeoutSeconds kills a program that overruns; the rest run normally.
Reset-Harness
$completed = [System.Collections.Generic.List[object]]::new()
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$batch = Invoke-PkProcessBatch -MaxConcurrent 2 -TimeoutSeconds 2 -OnComplete { param($c, $r) $completed.Add($r) }.GetNewClosure() -Commands @(
    @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1'; Name = 'slow' },
    @{ FilePath = $cmdExe; Arguments = '/c exit 0'; Name = 'fast' })
$sw.Stop()
$slow = @($batch.Results | Where-Object { $_.Command['Name'] -eq 'slow' })
$fast = @($batch.Results | Where-Object { $_.Command['Name'] -eq 'fast' })
Test-Assert ($slow.Count -eq 1 -and $slow[0].TimedOut -and $slow[0].ExitCode -ne 0 -and $sw.Elapsed.TotalSeconds -lt 15) ("batch: -TimeoutSeconds kills an overrunning program and marks it TimedOut (" + [int]$sw.Elapsed.TotalSeconds + "s)")
Test-Assert ($fast.Count -eq 1 -and -not $fast[0].TimedOut -and $fast[0].ExitCode -eq 0 -and -not $batch.Aborted) "and the others finish normally, not TimedOut"
Test-Assert ($completed.Count -eq 2) "a timed-out program still goes through -OnComplete"
# A program whose own child holds the output open: the whole tree is killed,
# so the output closes at once instead of after the 15-second stream wait.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$batch = Invoke-PkProcessBatch -MaxConcurrent 1 -TimeoutSeconds 2 -Commands @(@{ FilePath = $cmdExe; Arguments = ('/c ""' + $pingExe + '" -n 30 127.0.0.1"') })
$sw.Stop()
$r = @($batch.Results)[0]
Test-Assert ($r.TimedOut -and -not $r.StreamTimedOut -and $sw.Elapsed.TotalSeconds -lt 10) ("batch: a timeout kills the program's children too (" + [int]$sw.Elapsed.TotalSeconds + "s, StreamTimedOut=" + $r.StreamTimedOut + ")")
$j = Start-PkProcess -FilePath $cmdExe -Arguments '/c exit 0'
$null = Wait-PkProcess -Process $j.Proc -TimeoutMs 5000
Test-Assert (-not (Stop-PkProcessTree -Process $j.Proc)) "Stop-PkProcessTree reports `$false for a program that already exited"
$j.Proc.Dispose()

# Every other place the kit kills a program kills its children too: a
# Invoke-PkProcessWithTimeout overrun, and the dispatcher's force-stop
# after an abort. Each test's ping has its own count, so a surviving one
# can be found by its command line.
function Get-HarnessPingCount([int]$Count) {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -like ("*-n " + $Count + " 127.0.0.1*") }).Count
}
$nestedPing = { param($n) '/c ""' + $pingExe + '" -n ' + $n + ' 127.0.0.1"' }
try { $null = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments (& $nestedPing 41) -TimeoutMs 1500 } catch { }  # the overrun throw is expected
Test-Assert ((Get-HarnessPingCount 41) -eq 0) "Invoke-PkProcessWithTimeout: an overrun kills the program's children too"
Reset-Harness
$abortTimer = [PowerShell]::Create()
$null = $abortTimer.AddScript({ [System.Threading.Thread]::Sleep(1500); [PkConsoleCtrl]::AbortRequested = $true })
$abortTimerHandle = $abortTimer.BeginInvoke()
$batch = Invoke-PkProcessBatch -AbortTimeoutSeconds 1 -Commands @(@{ FilePath = $cmdExe; Arguments = (& $nestedPing 43) })
$null = $abortTimer.EndInvoke($abortTimerHandle); $abortTimer.Dispose()
$several = @(45, 46, 47 | ForEach-Object { Start-PkProcess -FilePath $cmdExe -Arguments (& $nestedPing $_) })
Start-Sleep -Milliseconds 500
$killedSeveral = Stop-PkProcessTree -Process @($several | ForEach-Object { $_.Proc })
Test-Assert ($killedSeveral -and (Get-HarnessPingCount 45) -eq 0 -and (Get-HarnessPingCount 46) -eq 0 -and (Get-HarnessPingCount 47) -eq 0 -and @($several | Where-Object { -not $_.Proc.HasExited }).Count -eq 0) "Stop-PkProcessTree kills several programs and their children in one call"
foreach ($j in $several) { $j.Proc.Dispose() }
# A parent and its own child in the same call: both die, and the call says
# it killed them. Section AJ covers taskkill failing for part of a tree.
$parentJob = Start-PkProcess -FilePath $cmdExe -Arguments (& $nestedPing 48)
$childProc = $null
$waitChild = [System.Diagnostics.Stopwatch]::StartNew()
while ($null -eq $childProc -and $waitChild.Elapsed.TotalSeconds -lt 5) {
    $childCim = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $parentJob.Proc.Id) | Where-Object { $_.Name -eq 'PING.EXE' })
    if ($childCim.Count -gt 0) { $childProc = [System.Diagnostics.Process]::GetProcessById([int]$childCim[0].ProcessId) } else { Start-Sleep -Milliseconds 100 }
}
$killedPair = $false
if ($null -ne $childProc) { $killedPair = Stop-PkProcessTree -Process @($parentJob.Proc, $childProc) }
Test-Assert ($null -ne $childProc -and $killedPair -and $parentJob.Proc.HasExited -and $childProc.HasExited) ("Stop-PkProcessTree kills a parent and its child passed together, and says so (found child: " + ($null -ne $childProc) + ", returned: " + $killedPair + ")")
$parentJob.Proc.Dispose(); if ($null -ne $childProc) { $childProc.Dispose() }
# A large kill: taskkill prints a line per process it kills (three per
# `cmd /c ping` tree). Left unread, that fills its output pipe and taskkill
# blocks until the 10 s wait gives up, leaving most children running.
$many = @(1..40 | ForEach-Object { Start-PkProcess -FilePath $cmdExe -Arguments (& $nestedPing 49) })
$waitMany = [System.Diagnostics.Stopwatch]::StartNew()
while ((Get-HarnessPingCount 49) -lt 40 -and $waitMany.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
$startedMany = Get-HarnessPingCount 49
$swMany = [System.Diagnostics.Stopwatch]::StartNew()
$killedMany = Stop-PkProcessTree -Process @($many | ForEach-Object { $_.Proc })
$swMany.Stop()
$leftMany = Get-HarnessPingCount 49
Test-Assert ($startedMany -eq 40 -and $killedMany -and $leftMany -eq 0 -and $swMany.Elapsed.TotalSeconds -lt 5) ("Stop-PkProcessTree kills 40 trees in one call, quickly, with none left (started " + $startedMany + ", " + [Math]::Round($swMany.Elapsed.TotalSeconds, 1) + "s, " + $leftMany + " left)")
foreach ($j in $many) { try { if (-not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }; $j.Proc.Dispose() }  # cleanup after a failure; already-exited is fine
Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -like '*-n 49 127.0.0.1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Test-Assert ($batch.Aborted -and $batch.ForceKilledCount -eq 1 -and (Get-HarnessPingCount 43) -eq 0) ("dispatch: the force-stop after an abort kills the program's children too (aborted=" + $batch.Aborted + ", force-killed=" + $batch.ForceKilledCount + ")")
Reset-PkAbortState
$threw = $false
try { $null = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -TimeoutSeconds -1 } catch { $threw = ($_.ToString() -like '*-TimeoutSeconds*') }
Test-Assert $threw "a negative -TimeoutSeconds is refused"

# An aborted group still gets -GroupCompleteCallback (the README warns about
# this - a caller zipping a folder there must check for the abort first).
Reset-Harness
Request-PkAbort
$called = @{ Count = 0; SawAbort = $false }
$feed = @{ Given = $false }
$d = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
    -JobFinalize { param($job, $pending) $null = Complete-PkProcess -Job $job } `
    -GroupCompleteCallback { param($g) $called.Count++; $called.SawAbort = [bool](Test-PkCancelRequested) }.GetNewClosure()
Test-Assert ($d.Aborted -and $called.Count -eq 1 -and $called.SawAbort) "an aborted group still gets its -GroupCompleteCallback, and Test-PkCancelRequested is true inside it"
Reset-PkAbortState
Write-Host ""

# ==============================================================================
Write-Host "=== U: pressing Ctrl+C again ===" -ForegroundColor Cyan
# [PkConsoleCtrl]::OnInterrupt is what the native handler calls for each
# Ctrl+C/Ctrl+Break press during a run, so calling it here is a key press
# minus Windows. Real console events are covered separately.

# The press sequence: start the abort, skip the drain, then let it through.
Reset-Harness
[PkConsoleCtrl]::SkipDebounceMs = 0
try {
    $presses = @([PkConsoleCtrl]::OnInterrupt('Ctrl+C'), [PkConsoleCtrl]::OnInterrupt('Ctrl+C'), [PkConsoleCtrl]::OnInterrupt('Ctrl+C'))
} finally {
    [PkConsoleCtrl]::SkipDebounceMs = 1000
}
Test-Assert ($presses[0] -and $presses[1] -and -not $presses[2]) ("the 1st and 2nd presses are handled, the 3rd is passed on to PowerShell (" + ($presses -join ',') + ")")
Test-Assert ([PkConsoleCtrl]::AbortRequested -and [PkConsoleCtrl]::SkipDrain) "the 1st press starts the abort and the 2nd skips the drain"
Reset-PkAbortState
Test-Assert (-not [PkConsoleCtrl]::AbortRequested -and -not [PkConsoleCtrl]::SkipDrain -and $null -eq [PkConsoleCtrl]::PressedKey) "Reset-PkAbortState clears the presses"

# A double tap or a held key only counts once.
Reset-Harness
$null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C')
$null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C')
$null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C')
Test-Assert ([PkConsoleCtrl]::AbortRequested -and -not [PkConsoleCtrl]::SkipDrain) "presses in quick succession count as one"

# The notice names what started the abort, and says how to skip the wait.
Reset-Harness
$null = [PkConsoleCtrl]::OnInterrupt('Ctrl+Break')
$null = Test-PkAbortSignal
$notice = @($script:messages | Where-Object { $_.Message -like '*Ctrl+Break detected*Press Ctrl+C again*' })
Test-Assert ($notice.Count -eq 1 -and (Get-PkAbortTriggerLabel) -eq 'Ctrl+Break') ("Ctrl+Break is announced as Ctrl+Break, with how to skip the wait (label: " + (Get-PkAbortTriggerLabel) + ")")
Reset-Harness
Request-PkAbort
$null = Test-PkAbortSignal
$notice = @($script:messages | Where-Object { $_.Message -like '*Abort requested*' -and $_.Message -notlike '*Ctrl+C*' })
Test-Assert ($notice.Count -eq 1 -and (Get-PkAbortTriggerLabel) -eq 'Request-PkAbort') ("an abort from code isn't announced as Ctrl+C (label: " + (Get-PkAbortTriggerLabel) + ")")
# Once an abort from code is under way, a single press skips the wait.
$null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C')
Test-Assert ([PkConsoleCtrl]::SkipDrain) "a press during an abort started from code skips the drain right away"

# The force-stop notice says why.
Reset-Harness
$reasons = @((& (Get-Module ParallelKit) Get-PkForceStopReason -TimeoutSeconds 5))
$null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C'); [PkConsoleCtrl]::SkipDrain = $true
$reasons += & (Get-Module ParallelKit) Get-PkForceStopReason -TimeoutSeconds 5
[PkConsoleCtrl]::IsCloseEvent = $true
$reasons += & (Get-Module ParallelKit) Get-PkForceStopReason -TimeoutSeconds 5
Test-Assert ($reasons[0] -like '*within 5s*' -and $reasons[1] -like '*pressed again*' -and $reasons[2] -like '*window is closing*') ("the force-stop notice gives the real reason (" + ($reasons -join ' | ') + ")")

# Presses from another thread while a run waits, as the native handler would.
function Start-HarnessPresses {
    $timer = [PowerShell]::Create()
    $null = $timer.AddScript({
        # 1.5s gives a slow machine time to start everything before the abort.
        [System.Threading.Thread]::Sleep(1500); $null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C')
        [System.Threading.Thread]::Sleep(1800); $null = [PkConsoleCtrl]::OnInterrupt('Ctrl+C')
    })
    return @{ PS = $timer; Handle = $timer.BeginInvoke() }
}

# A batch: the second press cuts the 25s drain short, and the script carries on.
Reset-Harness
$presser = Start-HarnessPresses
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$after = @{ Ran = $false }
$batch = Invoke-PkRun {
    $b = Invoke-PkProcessBatch -Commands @(1..3 | ForEach-Object { @{ FilePath = $pingExe; Arguments = '-n 15 127.0.0.1' } }) -MaxConcurrent 3 -AbortTimeoutSeconds 25
    $after.Ran = $true
    $b
}.GetNewClosure()
$sw.Stop()
$null = $presser.PS.EndInvoke($presser.Handle); $presser.PS.Dispose()
Test-Assert ($batch.Aborted -and $batch.ForceKilledCount -eq 3 -and $sw.Elapsed.TotalSeconds -lt 8 -and $after.Ran) ("batch: a second Ctrl+C force-stops running programs right away (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s, killed " + $batch.ForceKilledCount + "; the programs run 15s)")
Test-Assert (@($script:messages | Where-Object { $_.Message -like '*force-stopping 3 job(s) now: Ctrl+C was pressed again*' }).Count -eq 1) "and the force-stop says why"

# Runspace jobs: the same, and the workers are force-stopped.
Reset-Harness
$presser = Start-HarnessPresses
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$rsOut = Invoke-PkRun {
    Invoke-PkRunspaceJobs -MaxParallel 3 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })) -DrainTimeoutSeconds 25 `
        -WorkerScript { param([int]$Id) for ($i = 0; $i -lt 150; $i++) { [System.Threading.Thread]::Sleep(100) }; $Id }
}.GetNewClosure()
$sw.Stop()
$null = $presser.PS.EndInvoke($presser.Handle); $presser.PS.Dispose()
Test-Assert ($rsOut.Aborted -and $rsOut.ForceStoppedCount -eq 3 -and $sw.Elapsed.TotalSeconds -lt 8) ("runspace jobs: a second Ctrl+C force-stops running workers right away (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s, stopped " + $rsOut.ForceStoppedCount + "; the workers run 15s)")

# The handler thread a window close parks stays parked until the run ends,
# not just the drain, so the rest of the run gets Windows' few seconds.
Reset-Harness
$parked = @{ AfterDrain = $null }
$poll = @{ Count = 0 }
Invoke-PkRun {
    $null = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 })) `
        -WorkerScript { param([int]$Id) for ($i = 0; $i -lt 100; $i++) { if (Test-PkCancelRequested) { break }; [System.Threading.Thread]::Sleep(50) }; $Id } `
        -PollCallback { $poll.Count++; if ($poll.Count -eq 3) { Request-PkAbort } }.GetNewClosure()
    $parked.AfterDrain = [PkConsoleCtrl]::DrainComplete.IsSet
}.GetNewClosure()
Test-Assert ($parked.AfterDrain -eq $false -and [PkConsoleCtrl]::DrainComplete.IsSet) ("the handler thread is released when the run ends, not when the drain does (set after drain: " + $parked.AfterDrain + ")")
Reset-PkAbortState
Write-Host ""

# ==============================================================================
Write-Host "=== V: real console events (Ctrl+C, Ctrl+Break, window close) ===" -ForegroundColor Cyan
# Everything above fakes the abort flags. Here Windows itself calls the kit's
# handler. Each scenario runs a child PowerShell in a console of its own (a
# hidden window), and the events go to that console only: Ctrl+C/Ctrl+Break
# from a helper process that attaches to it, a close as WM_CLOSE to its
# window. Nothing is ever sent to the console this harness runs in.
#
# The child also registers a probe handler after the kit's, so Windows calls
# it first. If the probe never saw the first event, Windows didn't deliver
# it, and the scenario is skipped rather than blamed on the kit.

if (-not ([System.Management.Automation.PSTypeName]'PkHarnessWin').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PkHarnessWin {
    [DllImport("user32.dll", SetLastError = true)] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
}
'@
}

$consoleDir = Join-Path $env:TEMP ("pk-harness-console-" + $PID)
$null = New-Item -ItemType Directory -Force -Path $consoleDir
$childScript  = Join-Path $consoleDir 'child.ps1'
$senderScript = Join-Path $consoleDir 'sender.ps1'

# Logs are "<UTC ticks> <text>" lines, so times compare across processes.
[System.IO.File]::WriteAllText($childScript, @'
param([string]$KitPath, [string]$LogFile, [string]$Mode, [int]$AbortTimeoutSeconds)
Set-StrictMode -Version Latest
$global:PkChildLog = $LogFile
function global:Write-ChildLog([string]$Message) { [System.IO.File]::AppendAllText($global:PkChildLog, ([DateTime]::UtcNow.Ticks.ToString() + " " + $Message + "`r`n")) }
Write-ChildLog "started"
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class PkHarnessProbe {
    public delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);
    [DllImport("kernel32.dll", EntryPoint = "SetConsoleCtrlHandler", SetLastError = true)] public static extern bool SetIgnoreCtrlC(IntPtr none, bool ignore);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    private static HandlerRoutine _h;
    private static string _path;
    public static bool Register(string path) { _path = path; _h = new HandlerRoutine(H); return SetConsoleCtrlHandler(_h, true); }
    private static bool H(uint t) {
        // A lost line only makes the harness skip; a throw here would end the process.
        try { File.AppendAllText(_path, DateTime.UtcNow.Ticks.ToString() + " event " + t + "\r\n"); } catch { }
        return false;
    }
}
"@
# A process started from a tool may inherit "ignore Ctrl+C"; a user's console doesn't.
$null = [PkHarnessProbe]::SetIgnoreCtrlC([IntPtr]::Zero, $false)
$hwnd = [int64][PkHarnessProbe]::GetConsoleWindow()
. $KitPath
$null = Initialize-ParallelKit
$null = [PkHarnessProbe]::Register($LogFile + ".events")
Set-PkMessageHandler { param($Message, $Level) Write-ChildLog ("kit " + $Message) }
Write-ChildLog ("hwnd " + $hwnd)
if ($Mode -eq "run") {
    $ping = Join-Path $env:SystemRoot "System32\ping.exe"
    $feed = @{ Given = $false }
    $params = @{
        GroupProvider       = { if ($feed.Given) { return $null }; $feed.Given = $true; return "g" }.GetNewClosure()
        JobBuilder          = { param($g) return @(@{ FilePath = $ping; Arguments = "-n 60 127.0.0.1"; N = 1 }, @{ FilePath = $ping; Arguments = "-n 60 127.0.0.1"; N = 2 }) }.GetNewClosure()
        JobFinalize         = { param($job, $pending) $null = Complete-PkProcess -Job $job }
        JobAbortCleanup     = { param($job) Write-ChildLog ("cleanup " + $job["N"]) }
        MaxConcurrent       = 2
        AbortTimeoutSeconds = $AbortTimeoutSeconds
    }
    Write-ChildLog "ready"
    $r = Invoke-PkRun { Invoke-PkProcessDispatch @params }.GetNewClosure()
    Write-ChildLog ("returned Aborted=" + $r.Aborted + " ForceKilledCount=" + $r.ForceKilledCount)
}
Write-ChildLog "idle"
foreach ($i in 1..60) { Start-Sleep -Seconds 1 }
Write-ChildLog "END"
'@)

[System.IO.File]::WriteAllText($senderScript, @'
param([int]$TargetPid, [int]$EventType, [string]$LogFile)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PkHarnessSender {
    public delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
    private static HandlerRoutine _swallow = new HandlerRoutine(Swallow);
    private static bool Swallow(uint ctrlType) { return true; }
    public static string Send(uint pid, uint ev) {
        FreeConsole();
        if (!AttachConsole(pid)) { return "attach-failed " + Marshal.GetLastWin32Error(); }
        // This helper is attached to the same console, so it gets the event
        // too. A handler, not the ignore-Ctrl+C flag: that doesn't cover Ctrl+Break.
        SetConsoleCtrlHandler(_swallow, true);
        long at = DateTime.UtcNow.Ticks;
        if (!GenerateConsoleCtrlEvent(ev, 0)) { return "send-failed " + Marshal.GetLastWin32Error(); }
        System.Threading.Thread.Sleep(300);
        FreeConsole();
        return "sent " + at;
    }
}
"@
$result = [PkHarnessSender]::Send([uint32]$TargetPid, [uint32]$EventType)
[System.IO.File]::AppendAllText($LogFile, ($result + "`r`n"))
'@)

function Read-HarnessLines {
    # The child may be writing; open for reading without locking it out.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $text = [System.IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return @() }   # caught mid-write; the next poll reads it
    return @($text -split "`r`n" | Where-Object { $_ -ne '' })
}

function Get-HarnessLogTicks {
    # The time of the first line whose text matches, or 0.
    param([object[]]$Lines, [string]$Pattern)
    foreach ($l in $Lines) {
        $sp = $l.IndexOf(' ')
        if ($sp -gt 0 -and $l.Substring($sp + 1) -like $Pattern) { return [int64]$l.Substring(0, $sp) }
    }
    return [int64]0
}

$hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$kitPath = Join-Path $PSScriptRoot "ParallelKit.ps1"
# Events: C = Ctrl+C, B = Ctrl+Break, X = window close. At = seconds after the
# child logs "ready" (or "idle" when there's no run), or 'idle' = just after
# the run has returned. An event after a Ctrl+C/Ctrl+Break also waits until
# that helper has reported back and 1.5s more (past the kit's 1s debounce):
# a helper still attached when the next event lands can be killed by it, and
# on a slow machine the helper itself can take seconds to start.
# WaitFor = what ends the scenario.
$scenarios = @(
    @{ Name = 'ctrlc';       Mode = 'run';   Timeout = 3;  Events = @(@{ Kind = 'C'; At = 1.5 }, @{ Kind = 'C'; At = 'idle' }); WaitFor = 'exit' }
    @{ Name = 'break';       Mode = 'run';   Timeout = 3;  Events = @(@{ Kind = 'B'; At = 1.5 });                              WaitFor = 'idle' }
    @{ Name = 'norun';       Mode = 'norun'; Timeout = 3;  Events = @(@{ Kind = 'C'; At = 0.5 });                              WaitFor = 'exit' }
    @{ Name = 'close';       Mode = 'run';   Timeout = 20; Events = @(@{ Kind = 'X'; At = 1.5 });                              WaitFor = 'exit' }
    @{ Name = 'ctrlc-close'; Mode = 'run';   Timeout = 20; Events = @(@{ Kind = 'C'; At = 1.5 }, @{ Kind = 'X'; At = 4.0 });   WaitFor = 'exit' }
    @{ Name = 'ctrlc-twice'; Mode = 'run';   Timeout = 20; Events = @(@{ Kind = 'C'; At = 1.5 }, @{ Kind = 'C'; At = 4.0 });   WaitFor = 'idle' }
)
foreach ($s in $scenarios) {
    $s.Log = Join-Path $consoleDir ($s.Name + '.log')
    $s.SendLog = Join-Path $consoleDir ($s.Name + '.send.log')
    $s.Next = 0; $s.LastEventAt = [int64]0; $s.Sent = [System.Collections.Generic.List[hashtable]]::new(); $s.Done = $false; $s.Killed = $false; $s.Skip = $null
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $childScript + '"'), '-KitPath', ('"' + $kitPath + '"'), '-LogFile', ('"' + $s.Log + '"'), '-Mode', $s.Mode, '-AbortTimeoutSeconds', $s.Timeout)
    # No -NoNewWindow: the child gets a console of its own.
    $s.Child = Start-Process -FilePath $hostExe -ArgumentList $childArgs -WindowStyle Hidden -PassThru
    $s.Launched = [DateTime]::UtcNow.Ticks
}

$senders = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$overall = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ($overall.Elapsed.TotalSeconds -lt 90 -and @($scenarios | Where-Object { -not $_.Done }).Count -gt 0) {
        $now = [DateTime]::UtcNow.Ticks
        foreach ($s in $scenarios) {
            if ($s.Done) { continue }
            $lines = @(Read-HarnessLines -Path $s.Log)
            if ((Get-HarnessLogTicks $lines 'started') -eq 0) {
                if (($now - $s.Launched) / 1e7 -gt 30) { $s.Skip = "the child PowerShell never started in a console of its own"; $s.Done = $true }
                continue
            }
            $baseLine = 'ready'
            if ($s.Mode -eq 'norun') { $baseLine = 'idle' }
            $base = Get-HarnessLogTicks $lines $baseLine
            $idle = Get-HarnessLogTicks $lines 'idle'
            if ($base -eq 0) {
                if (($now - $s.Launched) / 1e7 -gt 45 -or $s.Child.HasExited) { $s.Done = $true }   # judged below as a failure
                continue
            }
            if ($s.Next -lt $s.Events.Count) {
                $e = $s.Events[$s.Next]
                $due = $false
                if ($e.At -is [string]) { $due = ($idle -ne 0 -and ($now - $idle) / 1e7 -ge 0.5) }
                else { $due = (($now - $base) / 1e7 -ge [double]$e.At) }
                $keysIssued = @($s.Sent | Where-Object { $_.Kind -ne 'X' }).Count
                if ($due -and $keysIssued -gt 0) {
                    $reports = @(Read-HarnessLines -Path $s.SendLog)
                    if ($reports.Count -lt $keysIssued) { $due = $false }
                    else {
                        $lastReport = $reports[$reports.Count - 1]
                        if ($lastReport -like 'sent *' -and ($now - [int64]$lastReport.Substring(5)) / 1e7 -lt 1.5) { $due = $false }
                    }
                }
                if ($due -and -not $s.Child.HasExited) {
                    if ($e.Kind -eq 'X') {
                        $hwndLine = @($lines | Where-Object { $_ -like '* hwnd *' })[0]
                        $hwnd = [int64]($hwndLine.Substring($hwndLine.LastIndexOf(' ') + 1))
                        if ($hwnd -eq 0) { $s.Skip = "the child's console has no window to close"; $s.Done = $true; continue }
                        $posted = [PkHarnessWin]::PostMessage([IntPtr]$hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
                        $s.Sent.Add(@{ Kind = 'X'; Ticks = [DateTime]::UtcNow.Ticks; Ok = $posted })
                    } else {
                        $evType = 0
                        if ($e.Kind -eq 'B') { $evType = 1 }
                        $sendArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $senderScript + '"'), '-TargetPid', $s.Child.Id, '-EventType', $evType, '-LogFile', ('"' + $s.SendLog + '"'))
                        $senders.Add((Start-Process -FilePath $hostExe -ArgumentList $sendArgs -WindowStyle Hidden -PassThru))
                        $s.Sent.Add(@{ Kind = $e.Kind; Ticks = 0; Ok = $true })
                    }
                    $s.Next++
                    $s.LastEventAt = [DateTime]::UtcNow.Ticks
                }
            } else {
                $finished = $s.Child.HasExited
                if ($s.WaitFor -eq 'idle' -and $idle -ne 0) { $finished = $true }
                if ($finished -or ($now - $s.LastEventAt) / 1e7 -gt 12) { $s.Done = $true }
            }
        }
        [System.Threading.Thread]::Sleep(50)
    }
} finally {
    # Senders finish within a second of sending; give the last ones time to log.
    [System.Threading.Thread]::Sleep(1500)
    foreach ($p in $senders) {
        if (-not $p.WaitForExit(3000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    foreach ($s in $scenarios) {
        if (-not $s.Child.HasExited) {
            $s.Killed = $true
            foreach ($k in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $s.Child.Id))) { Stop-Process -Id $k.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $s.Child.Id -Force -ErrorAction SilentlyContinue
            $null = $s.Child.WaitForExit(5000)
        }
    }
}

try {
foreach ($s in $scenarios) {
    $label = "real " + $s.Name + ": "
    if ($null -ne $s.Skip) { Test-Skip ($label + $s.Skip); continue }
    $lines  = @(Read-HarnessLines -Path $s.Log)
    $events = @(Read-HarnessLines -Path ($s.Log + '.events'))
    $sends  = @(Read-HarnessLines -Path $s.SendLog)
    $baseLine = 'ready'
    if ($s.Mode -eq 'norun') { $baseLine = 'idle' }
    if ((Get-HarnessLogTicks $lines $baseLine) -eq 0) {
        Test-Assert $false ($label + "the child loaded the kit and started (log: " + (@($lines | Select-Object -Last 3) -join ' | ') + ")")
        continue
    }
    # Fill in when each Ctrl+C/Ctrl+Break was really sent, from the senders' logs.
    $keySends = @($s.Sent | Where-Object { $_.Kind -ne 'X' })
    $failedSend = @($sends | Where-Object { $_ -notlike 'sent *' })
    if ($failedSend.Count -gt 0) { Test-Skip ($label + "couldn't send the console event (" + ($failedSend -join ', ') + ")"); continue }
    $sentTicks = @($sends | ForEach-Object { [int64]$_.Substring(5) } | Sort-Object)
    if ($sentTicks.Count -lt $keySends.Count) { Test-Skip ($label + "a helper that sends Ctrl+C never reported back (" + $sentTicks.Count + " of " + $keySends.Count + ")"); continue }
    for ($i = 0; $i -lt $keySends.Count; $i++) { $keySends[$i].Ticks = $sentTicks[$i] }
    if (@($s.Sent | Where-Object { -not $_.Ok }).Count -gt 0) { Test-Skip ($label + "posting WM_CLOSE to the child's console failed"); continue }
    # Only the first event says anything about the machine: a later one that
    # never arrives is what a handler holding events back looks like.
    if ($events.Count -eq 0) { Test-Skip ($label + "Windows didn't deliver the console event to the child"); continue }

    $text = @($lines | ForEach-Object { $_.Substring($_.IndexOf(' ') + 1) })
    $has = { param($p) @($text | Where-Object { $_ -like $p }).Count -gt 0 }
    $cleanups = @($text | Where-Object { $_ -like 'cleanup *' }).Count
    $returnedTicks = Get-HarnessLogTicks $lines 'returned *'
    $exitTicks = [int64]0
    if (-not $s.Killed) { $exitTicks = $s.Child.ExitTime.ToUniversalTime().Ticks }
    $lastSent = $s.Sent[$s.Sent.Count - 1].Ticks
    $exitAfter = -1.0
    if ($exitTicks -ne 0) { $exitAfter = [math]::Round(($exitTicks - $lastSent) / 1e7, 2) }

    switch ($s.Name) {
        'ctrlc' {
            Test-Assert ((& $has 'kit *Ctrl+C detected*') -and (& $has 'returned Aborted=True ForceKilledCount=2') -and $cleanups -eq 2) ($label + "Ctrl+C in a run aborts it, cleans up both programs and the script carries on (cleanups: " + $cleanups + ")")
            Test-Assert ($exitAfter -ge 0 -and $exitAfter -lt 4 -and -not (& $has 'END')) ($label + "Ctrl+C after the run has ended stops the script as usual (exited " + $exitAfter + "s after the press)")
        }
        'break' {
            Test-Assert ((& $has 'kit *Ctrl+Break detected*') -and (& $has 'returned Aborted=True ForceKilledCount=2') -and $cleanups -eq 2) ($label + "Ctrl+Break in a run aborts it like Ctrl+C (cleanups: " + $cleanups + ")")
        }
        'norun' {
            Test-Assert ($exitAfter -ge 0 -and $exitAfter -lt 4) ($label + "with no run active, Ctrl+C stops the script as usual (exited " + $exitAfter + "s after the press)")
        }
        'close' {
            Test-Assert ((& $has 'kit *Window close detected*') -and $cleanups -eq 2 -and $exitAfter -ge 0 -and $exitAfter -lt 5.5) ($label + "closing the window stops the jobs, cleans up both and the process ends (cleanups: " + $cleanups + ", exited " + $exitAfter + "s after the close)")
        }
        'ctrlc-close' {
            $closeSeen = [int64]0
            foreach ($l in $events) { if ($l -like '* event 2') { $closeSeen = [int64]$l.Substring(0, $l.IndexOf(' ')) } }
            $closeDelay = -1.0
            if ($closeSeen -ne 0) { $closeDelay = [math]::Round(($closeSeen - $lastSent) / 1e7, 2) }
            Test-Assert ($closeDelay -ge 0 -and $closeDelay -lt 1 -and $cleanups -eq 2 -and (& $has 'kit *now: the window is closing*')) ($label + "a window close after Ctrl+C gets through at once and still cleans up (close seen " + $closeDelay + "s after it was sent, cleanups: " + $cleanups + ")")
        }
        'ctrlc-twice' {
            $cutShort = -1.0
            if ($returnedTicks -ne 0) { $cutShort = [math]::Round(($returnedTicks - $lastSent) / 1e7, 2) }
            Test-Assert ((& $has 'kit *now: Ctrl+C was pressed again*') -and (& $has 'returned Aborted=True ForceKilledCount=2') -and $cutShort -ge 0 -and $cutShort -lt 3 -and (& $has 'idle')) ($label + "a second Ctrl+C skips the 20s drain and the script carries on (run returned " + $cutShort + "s after the 2nd press)")
        }
    }
}
} finally {
    Remove-Item -LiteralPath $consoleDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""

# ==============================================================================
Write-Host "=== W: relative paths and the current location ===" -ForegroundColor Cyan
# Programs start in the caller's current location, which cd/Set-Location
# change but the process's working directory doesn't follow.
Reset-Harness
$here = Join-Path $env:TEMP ("pk-harness-wd-" + $PID)
$null = New-Item -ItemType Directory -Force -Path (Join-Path $here 'sub')
[System.IO.File]::WriteAllText((Join-Path $here 'pk-wd.cmd'), "@echo pk-wd ran in %CD%`r`n")
$gone = Join-Path $env:TEMP ("pk-harness-wd-gone-" + $PID)
$null = New-Item -ItemType Directory -Force -Path $gone
function Get-HarnessCd {
    # Where a program started by each entry point runs, via "cmd /c cd".
    $wd = @{}
    $wd.Batch = (Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c cd' })).Results[0].Stdout.Trim()
    $wd.WithTimeout = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd').Stdout.Trim()
    $started = Start-PkProcess -FilePath $cmdExe -Arguments '/c cd'
    $null = Wait-PkProcess -Process $started['Proc'] -TimeoutMs 10000
    $wd.StartProcess = (Complete-PkProcess -Job $started -Dispose).Stdout.Trim()
    $out = @{ Text = $null }
    $feed = @{ Given = $false }
    $null = Invoke-PkProcessDispatch -MaxConcurrent 1 `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c cd' }) }.GetNewClosure() `
        -JobFinalize { param($job, $pending) $out.Text = (Complete-PkProcess -Job $job).Stdout.Trim() }.GetNewClosure()
    $wd.Dispatch = $out.Text
    return $wd
}
Push-Location -LiteralPath $here
# %TEMP% can be an 8.3 short path (C:\Users\RUNNER~1\... on GitHub's
# runners); compare against the folder as PowerShell reports it.
$here = (Get-Location).ProviderPath
try {
    Test-Assert ([Environment]::CurrentDirectory -ne $here) ("precondition: the process's working directory isn't the test folder (" + [Environment]::CurrentDirectory + ")")
    $wd = Get-HarnessCd
    $wrong = @($wd.Keys | Where-Object { $wd[$_] -ine $here })
    Test-Assert ($wrong.Count -eq 0) ("every entry point starts programs in the current location by default (wrong: " + (@($wrong | ForEach-Object { $_ + '=' + $wd[$_] }) -join ', ') + ")")

    $relText = $null
    try { $relText = (Invoke-PkProcessWithTimeout -FilePath '.\pk-wd.cmd').Stdout.Trim() } catch { $relText = [string]$_ }
    $missingText = ''
    try { $null = Invoke-PkProcessWithTimeout -FilePath '.\no-such-tool.exe' } catch { $missingText = [string]$_ }
    Test-Assert ($missingText -like ("*'.\no-such-tool.exe' (" + (Join-Path $here 'no-such-tool.exe') + ")*")) ("a program that can't be started is named with the full path that was tried (" + $missingText + ")")
    $relBatch = (Invoke-PkProcessBatch -Commands @(@{ FilePath = '.\pk-wd.cmd' })).Results[0]
    Test-Assert ($relText -ieq ("pk-wd ran in " + $here) -and $null -eq $relBatch.StartError -and $relBatch.Stdout.Trim() -ieq ("pk-wd ran in " + $here)) ("a FilePath with a folder in it (.\pk-wd.cmd) is found relative to the current location (" + $relText + ")")

    $subText = $null
    try { $subText = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory 'sub').Stdout.Trim() } catch { $subText = [string]$_ }
    Test-Assert ($subText -ieq (Join-Path $here 'sub')) ("a relative WorkingDirectory is relative to the current location (" + $subText + ")")

    $null = New-PSDrive -Name PkHarnessWd -PSProvider FileSystem -Root $here -Scope Script
    try {
        Push-Location -LiteralPath 'PkHarnessWd:\'
        try { $onDrive = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd').Stdout.Trim() } finally { Pop-Location }
        $driveText = $null
        try { $driveText = (Invoke-PkProcessWithTimeout -FilePath 'PkHarnessWd:\pk-wd.cmd' -WorkingDirectory 'PkHarnessWd:\sub').Stdout.Trim() } catch { $driveText = [string]$_ }
    } finally { Remove-PSDrive -Name PkHarnessWd -Scope Script }
    Test-Assert ($onDrive -ieq $here) ("on a drive made with New-PSDrive, the program runs in the real folder behind it (" + $onDrive + ")")
    Test-Assert ($driveText -ieq ("pk-wd ran in " + (Join-Path $here 'sub'))) ("a FilePath and WorkingDirectory on a New-PSDrive drive are translated to the real folders (" + $driveText + ")")
    $homeText = $null
    try { $homeText = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory '~').Stdout.Trim() } catch { $homeText = [string]$_ }
    Test-Assert ($homeText -ieq (Resolve-Path -LiteralPath '~').ProviderPath) ("a WorkingDirectory of ~ is your home folder (" + $homeText + ")")

    Push-Location -LiteralPath 'HKLM:\'
    try { $fromReg = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd').Stdout.Trim() } finally { Pop-Location }
    Test-Assert ($fromReg -ieq $here) ("from a registry location, the program runs in the last file-system location (" + $fromReg + ")")

    Push-Location -LiteralPath $gone
    try {
        [System.IO.Directory]::Delete($gone, $true)   # Remove-Item refuses to delete the current location
        $fromGone = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd'
        Test-Assert ($fromGone.ExitCode -eq 0 -and $fromGone.Stdout.Trim().TrimEnd('\') -ieq [Environment]::CurrentDirectory.TrimEnd('\')) ("if the current folder has been deleted, the program runs in the process's working directory instead (" + $fromGone.Stdout.Trim() + ")")
    } finally { Pop-Location }

    $explicit = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory $env:SystemRoot
    Test-Assert ($explicit.Stdout.Trim() -ieq $env:SystemRoot) "an explicit WorkingDirectory still wins over the current location"
} finally {
    Pop-Location
    Remove-Item -LiteralPath $here, $gone -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""

# ==============================================================================
Write-Host "=== X: each worker job starts clean ===" -ForegroundColor Cyan
# Worker runspaces are reused from job to job. Each job should start in the
# caller's location, without anything an earlier job left behind.
Reset-Harness
$workerDir = Join-Path $env:TEMP ("pk-harness-worker-" + $PID)
$null = New-Item -ItemType Directory -Force -Path $workerDir
[System.IO.File]::WriteAllText((Join-Path $workerDir 'data.txt'), 'worker-data')
$cleanWorker = {
    param([int]$Id)
    $start = [pscustomobject]@{
        Id       = $Id
        Location = (Get-Location).ProviderPath
        Leak     = (Get-Variable -Name pkHarnessLeak -ValueOnly -ErrorAction SilentlyContinue)
        EAP      = [string]$ErrorActionPreference
        Data     = (Get-Content -LiteralPath '.\data.txt' -ErrorAction SilentlyContinue)
    }
    # Everything that could carry over to the next job on the same runspace.
    Set-Location -LiteralPath $env:SystemRoot
    $pkHarnessLeak = "from job " + $Id
    $ErrorActionPreference = 'Stop'
    $start
}
Push-Location -LiteralPath $workerDir
$workerDir = (Get-Location).ProviderPath   # the long form; %TEMP% can be an 8.3 path
try {
    $seen = [System.Collections.Generic.List[object]]::new()
    $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })) `
        -WorkerScript $cleanWorker -ResultHandler { param($r) $seen.Add($r) }.GetNewClosure()
    $badLocation = @($seen | Where-Object { $_.Location -ine $workerDir } | ForEach-Object { "job " + $_.Id + "=" + $_.Location })
    Test-Assert ($seen.Count -eq 3 -and $badLocation.Count -eq 0) ("each worker job starts in the caller's location, even after an earlier job changed folder (wrong: " + ($badLocation -join ', ') + ")")
    Test-Assert (@($seen | Where-Object { $_.Data -ne 'worker-data' }).Count -eq 0) "a relative path in a worker cmdlet is relative to the caller's location"
    $leaked = @($seen | Where-Object { $null -ne $_.Leak -or $_.EAP -ne 'Continue' } | ForEach-Object { "job " + $_.Id + ": leak=" + $_.Leak + " EAP=" + $_.EAP })
    Test-Assert ($leaked.Count -eq 0) ("variables a job sets, preference variables included, don't carry over to the next job (" + ($leaked -join '; ') + ")")

    $null = New-PSDrive -Name PkHarnessJobs -PSProvider FileSystem -Root $workerDir -Scope Script
    try {
        Push-Location -LiteralPath 'PkHarnessJobs:\'
        try {
            $onDrive = [System.Collections.Generic.List[object]]::new()
            $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 })) `
                -WorkerScript $cleanWorker -ResultHandler { param($r) $onDrive.Add($r) }.GetNewClosure()
        } finally { Pop-Location }
    } finally { Remove-PSDrive -Name PkHarnessJobs -Scope Script }
    Test-Assert ($onDrive.Count -eq 1 -and $onDrive[0].Location -ieq $workerDir) ("from a New-PSDrive drive, workers start in the real folder behind it (" + @($onDrive | ForEach-Object { $_.Location }) + ")")
} finally {
    Pop-Location
    Remove-Item -LiteralPath $workerDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""

# ==============================================================================
Write-Host "=== Y: output that's been dropped is freed during the run ===" -ForegroundColor Cyan
# 30 programs printing ~150 KB each. A caller who drops each output once it's
# handled shouldn't have the kit keep it alive until the run ends. Weak
# references show what a full GC can free while the last job is finishing.
# A few of the most recent jobs can still be referenced from the dispatch
# loop (5-7 at -MaxConcurrent 4, however long the run).
Reset-Harness
$chatty = @(1..30 | ForEach-Object { @{ FilePath = $cmdExe; Arguments = ('/c for /l %i in (1,1,1500) do @echo ' + ('x' * 100)) } })
$batchWeak = [System.Collections.Generic.List[System.WeakReference]]::new()
$batchSeen = @{ Alive = -1; Largest = 0 }
$null = Invoke-PkProcessBatch -Commands $chatty -MaxConcurrent 4 -OnComplete {
    param($command, $result)
    if ($result.Stdout.Length -gt $batchSeen.Largest) { $batchSeen.Largest = $result.Stdout.Length }
    $batchWeak.Add([System.WeakReference]::new($result.Stdout))
    $result.Stdout = $null
    $result.Stderr = $null
    if ($batchWeak.Count -eq 30) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
        $batchSeen.Alive = @($batchWeak | Select-Object -First 29 | Where-Object { $_.IsAlive }).Count
    }
}.GetNewClosure()
Test-Assert ($batchSeen.Largest -gt 100000) ("precondition: each program printed a lot (" + $batchSeen.Largest + " chars)")
Test-Assert ($batchSeen.Alive -ge 0 -and $batchSeen.Alive -le 15) ("batch: output dropped in -OnComplete can be freed before the batch ends (" + $batchSeen.Alive + " of 29 still held)")

$feed = @{ Given = $false }
$dispatchWeak = [System.Collections.Generic.List[System.WeakReference]]::new()
$dispatchSeen = @{ Alive = -1 }
$null = Invoke-PkProcessDispatch -MaxConcurrent 4 `
    -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'one big group' }.GetNewClosure() `
    -JobBuilder { param($g) foreach ($c in $chatty) { $c.Clone() } }.GetNewClosure() `
    -JobFinalize {
        param($job, $pending)
        $dispatchWeak.Add([System.WeakReference]::new((Complete-PkProcess -Job $job).Stdout))
        if ($dispatchWeak.Count -eq 30) {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect()
            $dispatchSeen.Alive = @($dispatchWeak | Select-Object -First 29 | Where-Object { $_.IsAlive }).Count
        }
    }.GetNewClosure()
Test-Assert ($dispatchSeen.Alive -ge 0 -and $dispatchSeen.Alive -le 15) ("dispatcher: a finished job's output can be freed before its group ends (" + $dispatchSeen.Alive + " of 29 still held)")
Write-Host ""

# ==============================================================================
Write-Host "=== Z: the kit loads as an in-memory module ===" -ForegroundColor Cyan
Reset-Harness
# Only the public functions are visible, and they come from the module.
$missingPublic = @($publicFunctions | Where-Object { -not (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) })
$visibleInternal = @('Invoke-PkProcessDispatchCore', 'Add-PkCrashedJob', 'New-PkBatchResult', 'Get-PkCallerFunction' | Where-Object { Get-Command -Name $_ -ErrorAction SilentlyContinue })
Test-Assert ($missingPublic.Count -eq 0 -and $visibleInternal.Count -eq 0 -and (Get-Command Invoke-PkRun).ModuleName -eq 'ParallelKit') ("only the public functions are visible, from module ParallelKit (missing: " + ($missingPublic -join ', ') + "; internal visible: " + ($visibleInternal -join ', ') + ")")

# A callback built without .GetNewClosure() sees the caller's variables,
# not ones of the same name inside the kit.
$results = [System.Collections.Generic.List[object]]::new()
$state = @{ Count = 0 }
$TimeoutSeconds = 99
$sawTimeout = @{ Value = $null }
$plainBatch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -OnComplete {
    param($c, $r)
    $results.Add('mine')
    $state.Count++
    $sawTimeout.Value = $TimeoutSeconds
}
$foreign = @($plainBatch.Results | Where-Object { $_ -isnot [System.Management.Automation.PSCustomObject] }).Count
Test-Assert ($plainBatch.Results.Count -eq 2 -and $foreign -eq 0 -and $results.Count -eq 2 -and $state.Count -eq 2) ("a plain -OnComplete's `$results/`$state are the caller's, not the batch's (batch results " + $plainBatch.Results.Count + ", caller's " + $results.Count + "/" + $state.Count + ")")
Test-Assert ($sawTimeout.Value -eq 99) ("a plain -OnComplete reads the caller's `$TimeoutSeconds, not the batch's parameter (" + $sawTimeout.Value + ")")
Remove-Variable -Name TimeoutSeconds
$outcome = @{}
$plainJobs = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -WorkerScript { param([int]$Id) @{ Id = ("job" + $Id) } } -ResultHandler { param($r) $outcome[$r.Id] = 1 }
$privateCall = @(Test-PkWorkerSafety -WorkerScript { param($N) Invoke-PkMessageHandler -Message 'x' -Level Info })
Test-Assert ($privateCall.Count -eq 1 -and $privateCall[0].Rule -eq 'MissingFunction') ("worker code calling one of the kit's private helpers is still flagged (" + (@($privateCall | ForEach-Object { $_.Rule }) -join ',') + ")")
Test-Assert ($outcome.Count -eq 1 -and @($plainJobs.PSObject.Properties).Count -eq 5) ("a plain -ResultHandler writes to the caller's `$outcome, not the kit's return value (caller's " + $outcome.Count + ")")
$ScriptBlock = 'mine'
$fromRun = Invoke-PkRun { $ScriptBlock }
Remove-Variable -Name ScriptBlock
Test-Assert ($fromRun -eq 'mine') ("Invoke-PkRun's block reads the caller's `$ScriptBlock, not Invoke-PkRun's parameter (" + $fromRun + ")")

# -SharedFunctionNames and Test-PkWorkerSafety find the caller's functions
# however the script was started. A script run from a prompt (& script)
# keeps its functions in its own scope, not global, so this needs a fresh
# process started with -Command.
$lookupScript = Join-Path $env:TEMP ("pk-lookup-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($lookupScript, @"
. '$kitPath'
function Get-LookupDouble { param(`$N) 2 * `$N }
function Get-LookupState { `$script:lookupState }
`$out = [System.Collections.Generic.List[object]]::new()
`$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ N = 3 }) -SharedFunctionNames Get-LookupDouble -WorkerScript { param(`$N) Get-LookupDouble -N `$N } -ResultHandler { param(`$r) `$out.Add(`$r) }.GetNewClosure()
Write-Output ('script fn=' + (`$out -join ','))
function Invoke-LookupOuter {
    function Get-LookupInner { param(`$N) 10 * `$N }
    `$inner = [System.Collections.Generic.List[object]]::new()
    `$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ N = 4 }) -SharedFunctionNames Get-LookupInner -WorkerScript { param(`$N) Get-LookupInner -N `$N } -ResultHandler { param(`$r) `$inner.Add(`$r) }.GetNewClosure()
    Write-Output ('inner fn=' + (`$inner -join ','))
}
Invoke-LookupOuter
Write-Output ('unlisted=' + (@(Test-PkWorkerSafety -WorkerScript { param(`$N) Get-LookupDouble -N `$N }) | ForEach-Object { `$_.Rule }))
Write-Output ('script var=' + (@(Test-PkWorkerSafety -WorkerScript { param(`$N) Get-LookupState } -SharedFunctionNames Get-LookupState) | ForEach-Object { `$_.Rule }))
"@)
$lookup = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments (ConvertTo-PkArgumentString @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ("& '" + $lookupScript + "'"))) -TimeoutMs 60000
[System.IO.File]::Delete($lookupScript)
$lookupOut = ([string]$lookup.Stdout + [string]$lookup.Stderr).Trim() -replace '\s+', ' '
Test-Assert ($lookupOut -match 'script fn=6' -and $lookupOut -match 'inner fn=40') ("in a script run from a prompt, -SharedFunctionNames finds the script's functions and ones defined inside a function (" + $lookupOut + ")")
Test-Assert ($lookupOut -match 'unlisted=MissingFunction' -and $lookupOut -match 'script var=ScriptVariable') "and Test-PkWorkerSafety still reads their source: unlisted ones and `$script: use are flagged"

# A module's private function can be shared, when the script that loaded
# the kit calls into that module.
$modDir = Join-Path $env:TEMP ("pk-harness-mod-" + $PID)
$null = New-Item -ItemType Directory -Force -Path $modDir
$modPath = Join-Path $modDir 'PkHarnessMod.psm1'
[System.IO.File]::WriteAllText($modPath, @'
function Get-ModPrivate { param($N) 100 + $N }
function Invoke-ModWork {
    $out = [System.Collections.Generic.List[object]]::new()
    $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ N = 5 }) -SharedFunctionNames Get-ModPrivate -WorkerScript { param($N) Get-ModPrivate -N $N } -ResultHandler { param($r) $out.Add($r) }.GetNewClosure()
    'module private=' + ($out -join ',')
}
Export-ModuleMember -Function Invoke-ModWork
'@)
$modScript = Join-Path $modDir 'use.ps1'
[System.IO.File]::WriteAllText($modScript, ". '" + $kitPath + "'`r`nImport-Module '" + $modPath + "'`r`nInvoke-ModWork`r`n. '" + $kitPath + "'`r`n'kit modules=' + @(Get-Module -Name ParallelKit).Count`r`n")
$modRun = Invoke-PkProcessWithTimeout -FilePath $selfExe -Arguments (ConvertTo-PkArgumentString @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ("& '" + $modScript + "'"))) -TimeoutMs 60000
Remove-Item -LiteralPath $modDir -Recurse -Force -ErrorAction SilentlyContinue
$modOut = ([string]$modRun.Stdout + [string]$modRun.Stderr).Trim() -replace '\s+', ' '
Test-Assert ($modOut -match 'module private=105') ("a module's private function can be shared with workers (" + $modOut + ")")
Test-Assert ($modOut -match 'kit modules=1') "loading the kit a second time leaves one ParallelKit module, not two"
Write-Host ""

# ==============================================================================
Write-Host "=== AA: callbacks inside a worker, and drives made inside a function ===" -ForegroundColor Cyan
# Inside a worker the kit's functions are plain copies, not a module, so only
# their pk-prefixed names keep them out of a closure-less callback's way.
Reset-Harness
$workerOut = [System.Collections.Generic.List[object]]::new()
$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ CmdExe = $cmdExe })) -ResultHandler { param($r) $workerOut.Add($r) }.GetNewClosure() -WorkerScript {
    param($CmdExe)
    # Every variable name visible from where this runs, up the scope chain.
    $probe = {
        $probeSeen = @{}
        for ($probeScope = 1; $probeScope -lt 40; $probeScope++) {
            try { foreach ($probeVar in (Get-Variable -Scope $probeScope -ErrorAction Stop)) { $probeSeen[$probeVar.Name] = $true } } catch { break }
        }
        ,@($probeSeen.Keys)
    }
    $baseline = & $probe
    $results = [System.Collections.Generic.List[object]]::new()
    $state = @{ Count = 0 }
    $TimeoutSeconds = 99
    $running = 'my running'
    $seenBy = @{}
    $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $CmdExe; Arguments = '/c exit 0' }, @{ FilePath = $CmdExe; Arguments = '/c exit 0' }) -OnComplete {
        param($cbCommand, $cbResult)
        $results.Add('mine')
        $state.Count++
        $seenBy.Timeout = $TimeoutSeconds
        $seenBy.OnComplete = & $probe
    }
    $feed = @{ Given = $false }
    $null = Invoke-PkProcessDispatch -MaxConcurrent 1 `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; $seenBy.Provider = & $probe; return 'g' } `
        -JobBuilder { param($cbGroup) $seenBy.Builder = & $probe; return @(@{ FilePath = $CmdExe; Arguments = '/c exit 0' }) } `
        -JobFinalize { param($cbJob, $cbPending) $null = Complete-PkProcess -Job $cbJob; $seenBy.Running = $running; $seenBy.Finalize = & $probe }
    # What a function's frame adds by itself, on top of what was already visible.
    $automatic = @('args', 'input', 'MyInvocation', 'PSBoundParameters', 'PSCmdlet', 'PSCommandPath', 'PSScriptRoot', 'foreach', 'switch', 'this', '_', 'cbCommand', 'cbResult', 'cbGroup', 'cbJob', 'cbPending', 'probeSeen', 'probeScope', 'probeVar')
    $extra = @{}
    foreach ($where in 'OnComplete', 'Provider', 'Builder', 'Finalize') {
        foreach ($n in $seenBy[$where]) {
            if ($baseline -notcontains $n -and $automatic -notcontains $n -and $n -notlike 'pk*' -and @('results', 'state', 'TimeoutSeconds', 'running', 'seenBy', 'batch', 'feed', 'probe', 'baseline', 'automatic', 'extra') -notcontains $n) { $extra[$n] = $true }
        }
    }
    [pscustomobject]@{
        BatchResults = $batch.Results.Count
        Foreign      = @($batch.Results | Where-Object { $_ -isnot [System.Management.Automation.PSCustomObject] }).Count
        Mine         = $results.Count
        State        = $state.Count
        Timeout      = $seenBy.Timeout
        Running      = $seenBy.Running
        Extra        = (@($extra.Keys | Sort-Object) -join ', ')
    }
}
$wr = $workerOut[0]
Test-Assert ($null -ne $wr -and $wr.BatchResults -eq 2 -and $wr.Foreign -eq 0 -and $wr.Mine -eq 2 -and $wr.State -eq 2) ("in a worker, a plain -OnComplete's `$results/`$state are the worker's, not the batch's (batch results " + $wr.BatchResults + ", worker's " + $wr.Mine + "/" + $wr.State + ")")
Test-Assert ($wr.Timeout -eq 99 -and $wr.Running -eq 'my running') ("in a worker, plain callbacks read the worker's `$TimeoutSeconds and `$running (" + $wr.Timeout + ", " + $wr.Running + ")")
Test-Assert ($wr.Extra -eq '') ("in a worker, no kit variable without the pk prefix is visible to a plain callback (found: " + $wr.Extra + ")")

# A drive made with New-PSDrive inside a function is only visible from there.
Reset-Harness
$driveDir = Join-Path $env:TEMP ("pk-harness-fndrive-" + $PID)
$null = New-Item -ItemType Directory -Force -Path (Join-Path $driveDir 'sub')
Push-Location -LiteralPath $driveDir
$driveDir = (Get-Location).ProviderPath   # the long form; %TEMP% can be an 8.3 path
Pop-Location
[System.IO.File]::WriteAllText((Join-Path $driveDir 'pk-fn.cmd'), "@echo pk-fn ran in %CD%`r`n")
function Test-HarnessFunctionDrive {
    param([string]$Root)
    $null = New-PSDrive -Name PkFnDrive -PSProvider FileSystem -Root $Root
    $sub = Join-Path $Root 'sub'
    $wrong = [System.Collections.Generic.List[string]]::new()
    $check = {
        param($what, $got)
        if (([string]$got).Trim() -ine $sub) { $wrong.Add($what + '=' + ([string]$got).Trim()) }
    }
    try { & $check 'timeout' (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory 'PkFnDrive:\sub').Stdout } catch { $wrong.Add('timeout threw') }
    try {
        $started = Start-PkProcess -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory 'PkFnDrive:\sub'
        $null = Wait-PkProcess -Process $started['Proc'] -TimeoutMs 10000
        & $check 'start' (Complete-PkProcess -Job $started -Dispose).Stdout
    } catch { $wrong.Add('start threw') }
    $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c cd'; WorkingDirectory = 'PkFnDrive:\sub' })
    & $check 'batch' $batch.Results[0].Stdout
    $inRun = Invoke-PkRun { Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c cd'; WorkingDirectory = 'PkFnDrive:\sub' }) }
    & $check 'batch in Invoke-PkRun' $inRun.Results[0].Stdout
    $feed = @{ Given = $false }
    $out = @{ Text = $null }
    $null = Invoke-PkProcessDispatch -MaxConcurrent 1 `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' } `
        -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c cd'; WorkingDirectory = 'PkFnDrive:\sub' }) } `
        -JobFinalize { param($j, $p) $out.Text = (Complete-PkProcess -Job $j).Stdout }
    & $check 'dispatch' $out.Text
    $fileText = $null
    try { $fileText = (Invoke-PkProcessWithTimeout -FilePath 'PkFnDrive:\pk-fn.cmd').Stdout.Trim() } catch { $fileText = [string]$_ }
    return [pscustomobject]@{ Wrong = ($wrong -join ', '); FileText = $fileText }
}
try { $fnDrive = Test-HarnessFunctionDrive -Root $driveDir } finally { Remove-Item -LiteralPath $driveDir -Recurse -Force -ErrorAction SilentlyContinue }
Test-Assert ($fnDrive.Wrong -eq '') ("a WorkingDirectory on a drive made inside the calling function works from every entry point (wrong: " + $fnDrive.Wrong + ")")
Test-Assert ($fnDrive.FileText -like 'pk-fn ran in *') ("and so does a FilePath on that drive (" + $fnDrive.FileText + ")")
$noDrive = $null
try { $null = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory 'PkNoSuchDrive:\x' } catch { $noDrive = [string]$_ }
Test-Assert ($noDrive -like '*could not start*') "a drive that doesn't exist anywhere still fails with a clear start error"
# PowerShell treats curly quotes as string delimiters too, so a path can't be
# allowed to end the literal it's embedded in when looked up in the caller's session.
$curly = [string][char]0x2019
$global:pkHarnessInjected = $false
try { $null = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory ('PkNoDrive' + $curly + '); $global:pkHarnessInjected = $true; (' + $curly + ':\x') } catch { $null = $_ }   # failing to start is expected here; only the flag matters
$injected = $global:pkHarnessInjected
Remove-Variable -Name pkHarnessInjected -Scope Global
Test-Assert (-not $injected) "a path with a curly quote stays a path when it's looked up in the caller's session"

# \tools and C:tools depend on a current drive and folder: PowerShell's, not
# the process's. (Only a real test when the process's folder is on another
# drive, which it is on GitHub's runners and usually elsewhere.)
Reset-Harness
$windows = $env:SystemRoot
$noDriveDir = $windows.Substring(2) + '\System32'
$expectDir = Join-Path $windows 'System32'
$incompleteResult = @{}
Push-Location -LiteralPath $windows
try {
    foreach ($case in @(@{ Name = 'no drive'; Path = $noDriveDir }, @{ Name = 'drive with no folder'; Path = ($windows.Substring(0, 2) + 'System32') })) {
        try { $incompleteResult[$case.Name] = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory $case.Path).Stdout.Trim() } catch { $incompleteResult[$case.Name] = [string]$_ }
    }
    Push-Location -LiteralPath 'HKLM:\'
    try { $incompleteResult['from the registry'] = (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments '/c cd' -WorkingDirectory $noDriveDir).Stdout.Trim() } catch { $incompleteResult['from the registry'] = [string]$_ }
    finally { Pop-Location }
    $fileNoDrive = $null
    try { $fileNoDrive = (Invoke-PkProcessWithTimeout -FilePath ($windows.Substring(2) + '\System32\cmd.exe') -Arguments '/c exit 5').ExitCode } catch { $fileNoDrive = [string]$_ }
} finally { Pop-Location }
$wrongDirs = @($incompleteResult.Keys | Where-Object { $incompleteResult[$_] -ine $expectDir } | ForEach-Object { $_ + '=' + $incompleteResult[$_] })
Test-Assert ($wrongDirs.Count -eq 0) ("a WorkingDirectory that depends on a current drive or folder follows PowerShell's location, not the process's (wrong: " + ($wrongDirs -join ', ') + ")")
Test-Assert ($fileNoDrive -eq 5) ("and so does a FilePath with no drive (" + $fileNoDrive + ")")

# A non-terminating error in a worker that finishes during an abort's drain
# is reported, the same as one that finishes in the main loop.
Reset-Harness
$poll = @{ Count = 0 }
$softOut = [System.Collections.Generic.List[object]]::new()
$softRun = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 })) -WorkerScript {
    param([int]$Id)
    for ($i = 0; $i -lt 100; $i++) { if (Test-PkCancelRequested) { break }; [System.Threading.Thread]::Sleep(50) }
    [System.Threading.Thread]::Sleep(500)
    Write-Error ("soft drain " + $Id)
    return $Id
} -PollCallback { $poll.Count++; if ($poll.Count -eq 3) { Request-PkAbort } }.GetNewClosure() -ResultHandler { param($r) $softOut.Add($r) }.GetNewClosure()
$softMessages = @($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like 'Runspace error: soft drain*' }).Count
Test-Assert ($softRun.Aborted -and $softRun.CrashedCount -eq 0 -and $softOut.Count -eq 2 -and $softMessages -eq 2) ("a non-terminating error during an abort's drain is reported (messages " + $softMessages + ", results " + $softOut.Count + ")")
$softErrorsProp = $softRun.PSObject.Properties['Errors']   # read safely: strict mode throws on a missing property
$softErrorIds = @()
if ($null -ne $softErrorsProp) { $softErrorIds = @($softErrorsProp.Value | ForEach-Object { $_.Job['Id'] } | Sort-Object) }
Test-Assert (($softErrorIds -join ',') -eq '1,2') ("and lands in Errors with its job (" + ($softErrorIds -join ',') + ")")
Reset-Harness
Write-Host ""

# ==============================================================================
Write-Host "=== AB: a finished job's slot is refilled without waiting out a sleep ===" -ForegroundColor Cyan

# Timing, so up to three tries: a busy machine can only make a run slower, and
# polling can't get under its floor however idle the machine is.
# Two 50 ms sleeps per program at -MaxConcurrent 1 can't average under 100 ms.
$bestPerProgram = [double]::MaxValue
for ($try = 0; $try -lt 3 -and $bestPerProgram -ge 90; $try++) {
    $shortCommands = foreach ($i in 1..30) { @{ FilePath = $cmdExe; Arguments = '/d /c exit 0' } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $shortBatch = Invoke-PkProcessBatch -Commands $shortCommands -MaxConcurrent 1
    $sw.Stop()
    $bestPerProgram = [Math]::Min($bestPerProgram, $sw.Elapsed.TotalMilliseconds / 30)
}
Test-Assert ($shortBatch.Results.Count -eq 30) "every short program has a result"
Test-Assert ($bestPerProgram -lt 90) ("short programs aren't held back by the poll (best average " + [int]$bestPerProgram + " ms each)")

# The same floor for runspace jobs: one 100 ms sleep per 20 ms worker.
$bestPerJob = [double]::MaxValue
for ($try = 0; $try -lt 3 -and $bestPerJob -ge 70; $try++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(foreach ($i in 1..20) { @{ Id = $i } })) -WorkerScript {
        param([int]$Id)
        $spin = [System.Diagnostics.Stopwatch]::StartNew()
        while ($spin.ElapsedMilliseconds -lt 20) { }
    } -ResultHandler { param($r) }
    $sw.Stop()
    $bestPerJob = [Math]::Min($bestPerJob, $sw.Elapsed.TotalMilliseconds / 20)
}
Test-Assert ($bestPerJob -lt 70) ("short workers aren't held back by the poll (best average " + [int]$bestPerJob + " ms each)")

# A -JobPollCompleted that keeps saying "not done" after a process exits must
# not leave that process's signaled handle in the wait, or the loop spins:
# first while the second program still runs, then with both exited.
$spinState = @{ Given = $false; Polls = 0 }
$spinRun = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($spinState.Given) { return $null }; $spinState.Given = $true; return 'g' }.GetNewClosure() `
    -JobBuilder { param($g) @{ FilePath = $cmdExe; Arguments = '/d /c exit 0' }, @{ FilePath = $pingExe; Arguments = '-n 2 127.0.0.1' } }.GetNewClosure() `
    -JobPollCompleted { param($job) $spinState.Polls++; $job['Proc'].HasExited -and $job['Stopwatch'].Elapsed.TotalMilliseconds -gt 2000 }.GetNewClosure() `
    -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job }
Test-Assert ($spinRun.GroupResults.Count -eq 1 -and $spinState.Polls -lt 500) ("a lagging -JobPollCompleted doesn't spin the loop (" + $spinState.Polls + " polls in 2 s)")

# More running programs than one wait can hold.
$wideCommands = foreach ($i in 1..70) { @{ FilePath = $pingExe; Arguments = '-n 2 127.0.0.1' } }
$wide = Invoke-PkProcessBatch -Commands $wideCommands -MaxConcurrent 70
$wideOk = @($wide.Results | Where-Object { $_.ExitCode -eq 0 }).Count
Test-Assert ($wideOk -eq 70) "70 programs at once all finish ($wideOk ok)"
$wideRun = Invoke-PkRunspaceJobs -MaxParallel 70 -JobParams (New-JobList -Jobs @(foreach ($i in 1..70) { @{ Id = $i } })) -WorkerScript {
    param([int]$Id)
    [System.Threading.Thread]::Sleep(500)
    return $Id
} -ResultHandler { param($r) }
Test-Assert ($wideRun.Aborted -eq $false -and $wideRun.CrashedCount -eq 0) "70 runspace jobs at once all finish"

# A starter whose .Proc isn't a Process still gets waited on and finished.
$fakeState = @{ Given = $false; Finished = 0; Started = [System.Diagnostics.Stopwatch]::StartNew() }
$fakeRun = Invoke-PkProcessDispatch -MaxConcurrent 2 `
    -GroupProvider { if ($fakeState.Given) { return $null }; $fakeState.Given = $true; return 'g' }.GetNewClosure() `
    -JobBuilder { param($g) @{ Fake = 1 }, @{ FilePath = $pingExe; Arguments = '-n 2 127.0.0.1' } }.GetNewClosure() `
    -JobStarter { param($job) if ($job['Fake']) { $job['Proc'] = 'not a process' } else { $s = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments']; foreach ($k in $s.Keys) { $job[$k] = $s[$k] } }; return $job } `
    -JobPollCompleted { param($job) if ($job['Fake']) { $fakeState.Started.ElapsedMilliseconds -gt 300 } else { $job['Proc'].HasExited } }.GetNewClosure() `
    -JobFinalize { param($job, $q) $fakeState.Finished++; if (-not $job['Fake']) { $null = Complete-PkProcess -Job $job } }.GetNewClosure() `
    -JobAbortCleanup { param($job) }
Test-Assert ($fakeState.Finished -eq 2 -and $fakeRun.JobStarterFailedCount -eq 0) "a job whose .Proc isn't a process doesn't stop the wait ($($fakeState.Finished) finished)"

# Dispatchers sharing a budget take turns: one with a queue must not retake each
# slot it frees before the other has seen it free. A starts first, so every run
# of A's would come before B's first if A held on to the slot.
$turnBudget = [System.Threading.SemaphoreSlim]::new(1, 1)
$turnLog = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$turnJobs = New-JobList -Jobs @(
    @{ Tag = 'A'; DelayMs = 0; Budget = $turnBudget; Log = $turnLog; Exe = $cmdExe },
    @{ Tag = 'B'; DelayMs = 300; Budget = $turnBudget; Log = $turnLog; Exe = $cmdExe })
$null = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams $turnJobs -ResultHandler { param($r) } -WorkerScript {
    param([string]$Tag, [int]$DelayMs, [System.Threading.SemaphoreSlim]$Budget, $Log, [string]$Exe)
    [System.Threading.Thread]::Sleep($DelayMs)
    $feed = @{ Given = $false }
    $null = Invoke-PkProcessDispatch -MaxConcurrent $Budget `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) foreach ($i in 1..30) { @{ FilePath = $Exe; Arguments = '/d /c ping -n 1 127.0.0.1 >nul' } } }.GetNewClosure() `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job; $Log.Enqueue($Tag) }.GetNewClosure()
}
$turnOrder = -join $turnLog.ToArray()
$turnBudget.Dispose()
$turnFirstB = $turnOrder.IndexOf('B')
Test-Assert ($turnOrder.Length -eq 60 -and $turnFirstB -ge 0 -and $turnFirstB -lt 15) ("dispatchers sharing a budget take turns ($turnFirstB of A's ran before B's first: $turnOrder)")

# The same loop inside a worker, where the wait helper is a plain copy.
$workerWait = [System.Collections.Generic.List[object]]::new()
$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ CmdExe = $cmdExe })) -WorkerScript {
    param([string]$CmdExe)
    $inner = Invoke-PkProcessBatch -Commands @(@{ FilePath = $CmdExe; Arguments = '/d /c exit 0' }, @{ FilePath = $CmdExe; Arguments = '/d /c ping -n 2 127.0.0.1 >nul' }) -MaxConcurrent 2
    return @($inner.Results | Where-Object { $_.ExitCode -eq 0 }).Count
} -ResultHandler { param($r) $workerWait.Add($r) }.GetNewClosure()
Test-Assert ($workerWait.Count -eq 1 -and $workerWait[0] -eq 2) "a batch inside a worker waits and finishes (results: $($workerWait -join ','))"
Reset-Harness
Write-Host ""

# ==============================================================================
Write-Host "=== AC: the dispatcher's per-job time limit ===" -ForegroundColor Cyan

function Invoke-LimitGroup {
    # One group of jobs through the dispatcher. Logs each finalized job.
    param([hashtable[]]$Jobs, [hashtable]$Extra = @{})
    $log = [System.Collections.Generic.List[object]]::new()
    $feed = @{ Given = $false }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dispatchParams = @{
        MaxConcurrent = 6; AbortTimeoutSeconds = 30
        GroupProvider = { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure()
        JobBuilder    = { param($g) return $Jobs }.GetNewClosure()
        JobFinalize   = {
            param($job, $q)
            $done = $null
            if ($job['Proc'] -is [System.Diagnostics.Process]) { $done = Complete-PkProcess -Job $job }
            $exit = $null
            if ($null -ne $done) { $exit = $done.ExitCode }
            $log.Add([pscustomobject]@{ Name = $job['Name']; TimedOut = $job['TimedOut']; ExitCode = $exit; At = $sw.Elapsed.TotalSeconds })
            if ($job['Retry'] -gt 0) { $job['Retry']--; $q.Enqueue($job) }
        }.GetNewClosure()
    }
    foreach ($k in $Extra.Keys) { $dispatchParams[$k] = $Extra[$k] }
    $result = $null
    $problem = $null
    try { $result = Invoke-PkProcessDispatch @dispatchParams } catch { $problem = [string]$_ }
    return @{ Log = $log; Result = $result; Problem = $problem; Secs = $sw.Elapsed.TotalSeconds }
}
function Get-LimitEntry { param($Run, [string]$Name) return ,@($Run.Log | Where-Object { $_.Name -eq $Name }) }
# The pings a test started, told apart by their -n count. Also used by section AG.
function Get-LimitPing { param([int]$N) return @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -like ("*-n " + $N + " 127.0.0.1*") }) }
function Get-LimitPingCount { param([int]$N) return @(Get-LimitPing $N).Count }

# -TimeoutSeconds, and a job's own key overriding it in both directions.
$limitRun = Invoke-LimitGroup -Extra @{ TimeoutSeconds = 2 } -Jobs @(
    @{ Name = 'slow'; FilePath = $cmdExe; Arguments = ('/c ""' + $pingExe + '" -n 37 127.0.0.1"') },
    @{ Name = 'fast'; FilePath = $cmdExe; Arguments = '/c exit 0' },
    @{ Name = 'optout'; FilePath = $pingExe; Arguments = '-n 4 127.0.0.1'; TimeoutSeconds = 0 },
    @{ Name = 'shorter'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1'; TimeoutSeconds = 0.5 })
$slow = Get-LimitEntry $limitRun 'slow'; $fast = Get-LimitEntry $limitRun 'fast'; $optout = Get-LimitEntry $limitRun 'optout'; $shorter = Get-LimitEntry $limitRun 'shorter'
Test-Assert ($null -eq $limitRun.Problem -and $slow.Count -eq 1 -and $slow[0].TimedOut -eq $true -and $slow[0].ExitCode -ne 0 -and $slow[0].At -ge 2 -and $slow[0].At -lt 8) ("-TimeoutSeconds kills an overrunning job, and -JobFinalize sees TimedOut (problem: " + $limitRun.Problem + ")")
Test-Assert ((Get-LimitPingCount 37) -eq 0) "and what it started is killed with it"
Test-Assert ($fast.Count -eq 1 -and $fast[0].TimedOut -eq $false -and $fast[0].ExitCode -eq 0) "a job that finishes in time has TimedOut = `$false"
Test-Assert ($optout.Count -eq 1 -and $optout[0].TimedOut -eq $false -and $optout[0].ExitCode -eq 0 -and $optout[0].At -ge 2.5) "a job's TimeoutSeconds = 0 opts out of -TimeoutSeconds"
Test-Assert ($shorter.Count -eq 1 -and $shorter[0].TimedOut -eq $true -and $shorter[0].At -lt 1.9) "a job's own TimeoutSeconds beats -TimeoutSeconds, and can be fractional"

# A job's key with no -TimeoutSeconds; a job without the key isn't limited.
$limitRun = Invoke-LimitGroup -Jobs @(
    @{ Name = 'limited'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1'; TimeoutSeconds = 1 },
    @{ Name = 'free'; FilePath = $pingExe; Arguments = '-n 3 127.0.0.1' })
$limited = Get-LimitEntry $limitRun 'limited'; $free = Get-LimitEntry $limitRun 'free'
Test-Assert ($limited.Count -eq 1 -and $limited[0].TimedOut -eq $true -and $limited[0].At -lt 5) ("a job's TimeoutSeconds works without -TimeoutSeconds (problem: " + $limitRun.Problem + ")")
Test-Assert ($free.Count -eq 1 -and $free[0].TimedOut -eq $false -and $free[0].ExitCode -eq 0) "and a job without the key runs to its end"

# Still in force while an abort waits for running jobs.
$limitCts = [System.Threading.CancellationTokenSource]::new()
$limitCts.CancelAfter(500)
$limitCleaned = [System.Collections.Generic.List[object]]::new()
$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'drain'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }) -Extra @{ TimeoutSeconds = 2; CancelToken = $limitCts.Token; JobAbortCleanup = { param($job) $limitCleaned.Add($job['Name']) }.GetNewClosure() }
$drain = Get-LimitEntry $limitRun 'drain'
Test-Assert ($null -ne $limitRun.Result -and $limitRun.Result.Aborted -and $limitRun.Result.ForceKilledCount -eq 0 -and $drain.Count -eq 1 -and $drain[0].TimedOut -eq $true -and $limitCleaned.Count -eq 0 -and $limitRun.Secs -lt 10) ("a limit fires during an abort's wait, and the job is finalized (" + [int]$limitRun.Secs + "s, problem: " + $limitRun.Problem + ")")
$limitCts.Dispose()

# A starter that sets no Stopwatch is still timed.
$noWatchStarter = { param($job) $s = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments']; $job['Proc'] = $s.Proc; $job['StdoutTask'] = $s.StdoutTask; $job['StderrTask'] = $s.StderrTask; return $job }
$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'nowatch'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' }) -Extra @{ TimeoutSeconds = 1; JobStarter = $noWatchStarter }
$noWatch = Get-LimitEntry $limitRun 'nowatch'
Test-Assert ($noWatch.Count -eq 1 -and $noWatch[0].TimedOut -eq $true -and $noWatch[0].At -lt 5) ("a starter with no Stopwatch is still timed (problem: " + $limitRun.Problem + ")")

# A job with no real process is left to its own -JobPollCompleted.
$customClock = [System.Diagnostics.Stopwatch]::StartNew()
$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'custom' }) -Extra @{
    TimeoutSeconds = 1
    JobStarter = { param($job) $job['Proc'] = 'not a process'; return $job }
    JobPollCompleted = { param($job) return ($customClock.Elapsed.TotalSeconds -ge 1.8) }.GetNewClosure()
}
$custom = Get-LimitEntry $limitRun 'custom'
Test-Assert ($null -eq $limitRun.Problem -and $null -ne $limitRun.Result -and $custom.Count -eq 1 -and $custom[0].TimedOut -eq $false -and $custom[0].At -ge 1.7) ("a job whose .Proc isn't a process isn't timed (problem: " + $limitRun.Problem + ")")

# A program that can't be stopped gets one try and one warning, not a taskkill
# on every pass. A Process that was never started can't be stopped or read.
Reset-Harness
$stuckClock = [System.Diagnostics.Stopwatch]::StartNew()
$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'stuck' }) -Extra @{
    TimeoutSeconds = 0.2
    JobStarter = { param($job) $job['Proc'] = [System.Diagnostics.Process]::new(); return $job }
    JobPollCompleted = { param($job) return ($stuckClock.Elapsed.TotalSeconds -ge 1) }.GetNewClosure()
    JobFinalize = { param($job, $q) }
}
$stuckWarnings = @($script:messages | Where-Object { $_.Level -eq 'Warn' -and $_.Message -like "*couldn't be stopped*" }).Count
Test-Assert ($null -eq $limitRun.Problem -and $null -ne $limitRun.Result -and $stuckWarnings -eq 1) ("a program that can't be stopped gets one warning and the run carries on (warnings " + $stuckWarnings + ", problem: " + $limitRun.Problem + ")")
Reset-Harness

# Fractional, and under 0.5 s: not rounded to 0, which would mean no limit.
$limitRun = Invoke-LimitGroup -Extra @{ TimeoutSeconds = 0.4 } -Jobs @(@{ Name = 'fraction'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' })
$fraction = Get-LimitEntry $limitRun 'fraction'
Test-Assert ($fraction.Count -eq 1 -and $fraction[0].TimedOut -eq $true -and $fraction[0].At -lt 5) "a fractional -TimeoutSeconds isn't rounded away"
$fractionBatch = Invoke-PkProcessBatch -TimeoutSeconds 0.4 -Commands @(@{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' })
Test-Assert ($fractionBatch.Results[0].TimedOut -eq $true) "and neither is the batch's"

# On the main thread too, a plain callback reads the caller's $TimeoutSeconds:
# reading the kit's 0 here would finish the job at once.
$TimeoutSeconds = 1.5
$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'plain'; FilePath = $cmdExe; Arguments = '/c exit 0' }) -Extra @{
    TimeoutSeconds = 30
    JobPollCompleted = { param($job) $job['Proc'].HasExited -and $job['Stopwatch'].Elapsed.TotalSeconds -ge $TimeoutSeconds }
}
Remove-Variable -Name TimeoutSeconds
$plain = Get-LimitEntry $limitRun 'plain'
Test-Assert ($plain.Count -eq 1 -and $plain[0].At -ge 1.4 -and $plain[0].At -lt 10) ("a plain -JobPollCompleted reads the caller's `$TimeoutSeconds, not the dispatcher's (finished at " + $(if ($plain.Count) { [Math]::Round($plain[0].At, 1) }) + " s)")

# A bad key fails that job's start, before anything runs.
Reset-Harness
$limitRun = Invoke-LimitGroup -Jobs @(
    @{ Name = 'word'; FilePath = $pingExe; Arguments = '-n 33 127.0.0.1'; TimeoutSeconds = 'soon' },
    @{ Name = 'minus'; FilePath = $pingExe; Arguments = '-n 33 127.0.0.1'; TimeoutSeconds = -1 },
    @{ Name = 'nan'; FilePath = $pingExe; Arguments = '-n 33 127.0.0.1'; TimeoutSeconds = 'NaN' })
$badKeyMessages = @($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like "*TimeoutSeconds must be*" }).Count
Test-Assert ($null -ne $limitRun.Result -and $limitRun.Result.JobStarterFailedCount -eq 3 -and $limitRun.Log.Count -eq 0 -and $badKeyMessages -eq 3) ("a bad TimeoutSeconds key is a failed start with a clear message (messages " + $badKeyMessages + ", problem: " + $limitRun.Problem + ")")
Reset-Harness

# A retry of a timed-out job gets a fresh clock.
$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'retry'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1'; Retry = 1 }) -Extra @{ TimeoutSeconds = 1 }
$retried = Get-LimitEntry $limitRun 'retry'
Test-Assert ($retried.Count -eq 2 -and $retried[0].TimedOut -and $retried[1].TimedOut -and ($retried[1].At - $retried[0].At) -ge 0.8) ("a retried job gets a fresh clock (" + $retried.Count + " runs, problem: " + $limitRun.Problem + ")")

$limitRun = Invoke-LimitGroup -Jobs @(@{ Name = 'x'; FilePath = $cmdExe; Arguments = '/c exit 0' }) -Extra @{ TimeoutSeconds = -1 }
Test-Assert ($null -ne $limitRun.Problem -and $limitRun.Problem -like '*-TimeoutSeconds must be*') "a negative -TimeoutSeconds is refused by the dispatcher"

# The batch: a command's own key, and a bad one still gets a result.
$keyBatch = Invoke-PkProcessBatch -MaxConcurrent 4 -TimeoutSeconds 1 -Commands @(
    @{ Name = 'own'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1'; TimeoutSeconds = 0.5 },
    @{ Name = 'optout'; FilePath = $pingExe; Arguments = '-n 3 127.0.0.1'; TimeoutSeconds = 0 },
    @{ Name = 'inherit'; FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' },
    @{ Name = 'bad'; FilePath = $pingExe; Arguments = '-n 33 127.0.0.1'; TimeoutSeconds = 'soon' })
$keyResult = @{}
foreach ($r in $keyBatch.Results) { $keyResult[$r.Command['Name']] = $r }
Test-Assert ($keyBatch.Results.Count -eq 4 -and $keyResult['own'].TimedOut -and $keyResult['inherit'].TimedOut) ("batch: a command's TimeoutSeconds key and -TimeoutSeconds both fire (" + $keyBatch.Results.Count + " results)")
Test-Assert ($keyResult.ContainsKey('optout') -and -not $keyResult['optout'].TimedOut -and $keyResult['optout'].ExitCode -eq 0) "batch: a command's TimeoutSeconds = 0 opts out"
Test-Assert ($keyResult.ContainsKey('bad') -and $keyResult['bad'].StartError -like '*TimeoutSeconds must be*' -and (Get-LimitPingCount 33) -eq 0) "batch: a bad TimeoutSeconds key is that command's StartError, and it doesn't run"
Reset-Harness

# Inside a worker, where the helpers are plain copies and a plain callback sees
# the kit's frames: it must read the worker's own $TimeoutSeconds.
$limitWorker = [System.Collections.Generic.List[object]]::new()
$limitOut = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ PingExe = $pingExe })) -ResultHandler { param($r) $limitWorker.Add($r) }.GetNewClosure() -WorkerScript {
    param([string]$PingExe)
    $TimeoutSeconds = 99
    $seen = @{ Value = $null }
    $feed = @{ Given = $false }
    $flags = [System.Collections.Generic.List[object]]::new()
    $null = Invoke-PkProcessDispatch -MaxConcurrent 1 -TimeoutSeconds 1 `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $PingExe; Arguments = '-n 30 127.0.0.1' }) }.GetNewClosure() `
        -JobPollCompleted { param($job) $seen.Value = $TimeoutSeconds; $job['Proc'].HasExited } `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job; $flags.Add($job['TimedOut']) }.GetNewClosure()
    return @{ Flags = ($flags -join ','); Seen = $seen.Value }
}
Test-Assert ($limitOut.CrashedCount -eq 0 -and $limitWorker.Count -eq 1 -and $limitWorker[0]['Flags'] -eq 'True') "a time limit works inside a worker"
Test-Assert ($limitWorker.Count -eq 1 -and $limitWorker[0]['Seen'] -eq 99) "and a plain callback there reads the worker's `$TimeoutSeconds, not the dispatcher's"
Reset-Harness
Write-Host ""

Write-Host "=== AD: repeated start failures are reported once, with a count ===" -ForegroundColor Cyan

function Get-StartMessageCount { param([string]$Like) return @($script:messages | Where-Object { $_.Message -like $Like }).Count }
$missing = 'pk-no-such-program.exe'
$missingCommands = @(1..5 | ForEach-Object { @{ FilePath = $missing; Arguments = "$_"; Tag = $_ } })

Reset-Harness
$completedCount = @{ N = 0 }
$collapsed = Invoke-PkProcessBatch -Commands $missingCommands -MaxConcurrent 2 -OnComplete { param($c, $r) $completedCount.N++ }.GetNewClosure()
Test-Assert (@($collapsed.Results | Where-Object { $_.StartError -like "*could not start '$missing'*" }).Count -eq 5) "every command that can't start still gets its own StartError"
Test-Assert ($completedCount.N -eq 0) "-OnComplete still skips commands that couldn't start"
Test-Assert ((Get-StartMessageCount "*$missing*") -eq 2) ("five failures of one program give two messages, the first and a summary (" + (Get-StartMessageCount "*$missing*") + ")")
Test-Assert ((Get-StartMessageCount "*4 more commands couldn't start '$missing'*") -eq 1) "the summary counts the ones it left out"
Test-Assert ((Get-StartMessageCount "*JobStarter*") -eq 0 -and (Get-StartMessageCount "*ProcessDispatch*") -eq 0) "batch messages don't name dispatcher internals"
Test-Assert (@($script:messages | Where-Object { $_.Message -like "*more command*" -and $_.Message -like "*could not start*" }).Count -eq 0) "the summary gives Windows' reason, without the per-command text"

Reset-Harness
$null = Invoke-PkProcessBatch -Commands @(@{ FilePath = $missing }) -MaxConcurrent 2
Test-Assert ((Get-StartMessageCount "*$missing*") -eq 1 -and (Get-StartMessageCount "*more command*") -eq 0) "one failure gets no summary"

Reset-Harness
$null = Invoke-PkProcessBatch -Commands @(@{ FilePath = $missing }, @{ FilePath = $missing }) -MaxConcurrent 2
Test-Assert ((Get-StartMessageCount "*1 more command couldn't start '$missing'*") -eq 1) "the summary reads right for one more"

Reset-Harness
$null = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(
    @{ FilePath = 'pk-missing-a.exe' }, @{ FilePath = 'pk-missing-b.exe' }, @{ FilePath = 'pk-missing-a.exe' },
    @{ FilePath = 'pk-missing-b.exe' }, @{ FilePath = 'pk-missing-a.exe' }, @{ FilePath = 'pk-missing-b.exe' })
Test-Assert ((Get-StartMessageCount "*pk-missing-a.exe*") -eq 2 -and (Get-StartMessageCount "*pk-missing-b.exe*") -eq 2) "different programs are reported separately"

Reset-Harness
$null = Invoke-PkProcessBatch -Commands @(@{ FilePath = 'PK-MISSING-C.exe' }, @{ FilePath = 'pk-missing-c.EXE' }) -MaxConcurrent 2
Test-Assert ((Get-StartMessageCount "*1 more command couldn't start*") -eq 1) "a program's name is matched as Windows matches it, ignoring case"

# On 7 the text of this failure names the working directory, so it differs
# between these: repeats have to be matched on Windows' error code.
Reset-Harness
$null = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(
    @{ FilePath = $missing; WorkingDirectory = $env:TEMP }, @{ FilePath = $missing; WorkingDirectory = $env:windir }, @{ FilePath = $missing; WorkingDirectory = $PSHOME })
Test-Assert ((Get-StartMessageCount "*$missing*") -eq 2) ("the same failure from different folders counts as a repeat (" + (Get-StartMessageCount "*$missing*") + ")")

# A different reason for the same program isn't a repeat.
Reset-Harness
$null = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(
    @{ FilePath = $cmdExe; Arguments = '/c exit 0'; WorkingDirectory = (Join-Path $env:TEMP 'pk-no-such-folder') },
    @{ FilePath = $cmdExe; Arguments = ('/c rem ' + ('x' * 33000)) })
Test-Assert ((Get-StartMessageCount "*couldn't start*") -eq 2 -and (Get-StartMessageCount "*more command*") -eq 0) "different reasons for one program are reported separately"

Reset-Harness
$mixed = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(
    @{ Name = 'bad'; FilePath = $cmdExe; Arguments = '/c exit 0'; WorkingDirectory = (Join-Path $env:TEMP 'pk-no-such-folder') },
    @{ Name = 'good1'; FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ Name = 'good2'; FilePath = $cmdExe; Arguments = '/c exit 0' })
$mixedOk = @($mixed.Results | Where-Object { $_.ExitCode -eq 0 -and $_.Command['Name'] -like 'good*' }).Count
Test-Assert ($mixedOk -eq 2 -and @($mixed.Results | Where-Object { $_.Command['Name'] -eq 'bad' -and $_.StartError }).Count -eq 1) "a command that can't start doesn't stop the good ones"

Reset-Harness
$badKeys = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(
    @{ FilePath = $cmdExe; Arguments = '/c exit 0'; TimeoutSeconds = 'soon' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0'; TimeoutSeconds = 'soon' }, @{ FilePath = $cmdExe; Arguments = '/c exit 0'; TimeoutSeconds = 'soon' })
Test-Assert ($badKeys.Results.Count -eq 3 -and (Get-StartMessageCount "*TimeoutSeconds must be*") -eq 2 -and (Get-StartMessageCount "*2 more commands*") -eq 1) "repeats of a bad TimeoutSeconds key are collapsed too"

# The summary isn't lost when a callback stops the batch.
Reset-Harness
$thrown = $null
try {
    $null = Invoke-PkProcessBatch -MaxConcurrent 3 -OnComplete { throw 'pk-callback-stop' } -Commands @(
        @{ FilePath = $missing }, @{ FilePath = $missing }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' })
} catch { $thrown = [string]$_ }
Test-Assert ((Get-StartMessageCount "*1 more command couldn't start '$missing'*") -eq 1) ("the summary still prints when -OnComplete throws (threw: " + $thrown + ")")

# Or when an abort ends the batch early.
Reset-Harness
$abortedBatch = Invoke-PkProcessBatch -MaxConcurrent 3 -AbortTimeoutSeconds 1 -OnComplete { Request-PkAbort } -Commands @(
    @{ FilePath = $missing }, @{ FilePath = $missing }, @{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $pingExe; Arguments = '-n 30 127.0.0.1' })
Test-Assert ($abortedBatch.Aborted -and (Get-StartMessageCount "*1 more command couldn't start '$missing'*") -eq 1) ("the summary still prints after an abort (aborted: " + $abortedBatch.Aborted + ")")

# The dispatcher's custom starters can throw anything, so it reports each one.
Reset-Harness
$dispatchMissing = Invoke-LimitGroup -Jobs @(
    @{ Name = 'a'; FilePath = $missing }, @{ Name = 'b'; FilePath = $missing }, @{ Name = 'c'; FilePath = $missing })
Test-Assert ($dispatchMissing.Result.JobStarterFailedCount -eq 3 -and (Get-StartMessageCount "*JobStarter failed to start a job*$missing*") -eq 3) "the dispatcher still reports every failed start"

# A bad key is refused before the starter runs, so don't blame the starter.
Reset-Harness
$null = Invoke-LimitGroup -Jobs @(@{ Name = 'x'; FilePath = $cmdExe; Arguments = '/c exit 0'; TimeoutSeconds = 'soon' })
Test-Assert ((Get-StartMessageCount "*ProcessDispatch: a job couldn't start:*TimeoutSeconds must be*") -eq 1 -and (Get-StartMessageCount "*JobStarter*") -eq 0) "a bad TimeoutSeconds key on a dispatcher job doesn't blame the JobStarter"

Reset-Harness
$collapseWorker = [System.Collections.Generic.List[object]]::new()
$collapseOut = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Missing = $missing })) -ResultHandler { param($r) $collapseWorker.Add($r) }.GetNewClosure() -WorkerScript {
    param([string]$Missing)
    $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $Missing }, @{ FilePath = $Missing }, @{ FilePath = $Missing }) -MaxConcurrent 2
    return @{ Failed = @($batch.Results | Where-Object { $_.StartError }).Count }
}
Test-Assert ($collapseOut.CrashedCount -eq 0 -and $collapseWorker.Count -eq 1 -and $collapseWorker[0]['Failed'] -eq 3) "start failures are handled inside a worker too"
Test-Assert ((Get-StartMessageCount "*$missing*") -eq 2) ("and collapsed there (" + (Get-StartMessageCount "*$missing*") + " messages)")
Reset-Harness
Write-Host ""

Write-Host "=== AE: a list in Arguments is quoted, one argument per element ===" -ForegroundColor Cyan

$argvExe = Join-Path $env:TEMP ("pk-argv-" + [guid]::NewGuid().ToString("N") + ".exe")
$argvSrc = [System.IO.Path]::ChangeExtension($argvExe, '.cs')
[System.IO.File]::WriteAllText($argvSrc, 'public static class PkArgv { public static void Main(string[] args) { foreach (string a in args) { System.Console.WriteLine("[" + a + "]"); } } }')
$csc = $null
try { $csc = Invoke-PkProcessWithTimeout -FilePath $cscExe -Arguments (ConvertTo-PkArgumentString @('/nologo', ('/out:' + $argvExe), $argvSrc)) } catch { Write-Host "  csc.exe failed to run: $_" }
[System.IO.File]::Delete($argvSrc)
$compiled = ($null -ne $csc -and $csc.ExitCode -eq 0 -and [System.IO.File]::Exists($argvExe))
Test-Assert $compiled "the argument-printing test program compiles"
if ($compiled) {
    function Get-ArgvText { param($Stdout) return (@(([string]$Stdout).Split([string[]]@("`r`n"), [System.StringSplitOptions]::RemoveEmptyEntries)) -join '') }
    function Get-BatchArgvText {
        param($ArgumentValue)
        $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $argvExe; Arguments = $ArgumentValue }) -MaxConcurrent 1
        return (Get-ArgvText $batch.Results[0].Stdout)
    }
    $spaced = @('C:\My Files\a.png', 'out.jxl')
    $spacedText = '[C:\My Files\a.png][out.jxl]'

    # All four entry points.
    $text = Get-BatchArgvText $spaced
    Test-Assert ($text -eq $spacedText) ("batch: an array is one argument per element (" + $text + ")")
    $feedArgs = @{ Given = $false }
    $gotArgs = @{ Text = $null }
    $null = Invoke-PkProcessDispatch -MaxConcurrent 1 `
        -GroupProvider { if ($feedArgs.Given) { return $null }; $feedArgs.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $argvExe; Arguments = $spaced }) }.GetNewClosure() `
        -JobFinalize { param($job, $q) $gotArgs.Text = (Complete-PkProcess -Job $job).Stdout }.GetNewClosure()
    $text = Get-ArgvText $gotArgs.Text
    Test-Assert ($text -eq $spacedText) ("dispatcher: an array is one argument per element (" + $text + ")")
    $text = $null
    try { $text = Get-ArgvText (Invoke-PkProcessWithTimeout -FilePath $argvExe -Arguments $spaced).Stdout } catch { $text = "threw: $_" }
    Test-Assert ($text -eq $spacedText) ("Invoke-PkProcessWithTimeout takes an array (" + $text + ")")
    $text = $null
    try {
        $started = Start-PkProcess -FilePath $argvExe -Arguments $spaced
        $null = Wait-PkProcess -Process $started['Proc'] -TimeoutMs 10000
        $text = Get-ArgvText (Complete-PkProcess -Job $started).Stdout
    } catch { $text = "threw: $_" }
    Test-Assert ($text -eq $spacedText) ("Start-PkProcess takes an array (" + $text + ")")

    # The kinds of list.
    $list = [System.Collections.Generic.List[string]]::new(); $list.Add('C:\My Files\a.png'); $list.Add('out.jxl')
    $started = Start-PkProcess -FilePath $argvExe -Arguments $list
    $null = Wait-PkProcess -Process $started['Proc'] -TimeoutMs 10000
    $text = Get-ArgvText (Complete-PkProcess -Job $started).Stdout
    Test-Assert ($text -eq $spacedText) ("a List[string] is quoted too (" + $text + ")")
    $arrayList = [System.Collections.ArrayList]::new(); $null = $arrayList.Add('two words')
    Test-Assert ((Get-BatchArgvText $arrayList) -eq '[two words]') "so is an ArrayList, even of one element"
    Test-Assert ((Get-BatchArgvText ([string[]]@('two words', 'x'))) -eq '[two words][x]') "and a [string[]]"
    Test-Assert ((Get-BatchArgvText @('two words')) -eq '[two words]') "a single-element array stays one argument"
    Test-Assert ((Get-BatchArgvText @(1, 2.5, 'x')) -eq '[1][2.5][x]') "numbers in a list become arguments"
    Test-Assert ((Get-BatchArgvText @()) -eq '') "an empty list is no arguments"
    Test-Assert ((Get-BatchArgvText $null) -eq '') "`$null is no arguments"
    Test-Assert ((Get-BatchArgvText 7) -eq '[7]') "a single number is one argument"

    # $null elements are dropped, the same from every route; '' is an argument.
    Test-Assert ((Get-BatchArgvText @('a', $null, 'b')) -eq '[a][b]') "a `$null element is dropped"
    Test-Assert ((Get-BatchArgvText @('a', '', 'b')) -eq '[a][][b]') "an empty string stays an argument"
    Test-Assert ((ConvertTo-PkArgumentString @('a', $null, 'b')) -eq 'a b') "ConvertTo-PkArgumentString drops a `$null element too"
    $withNull = @('a', $null, 'b')
    Test-Assert ((ConvertTo-PkArgumentString $withNull) -eq 'a b') "and from a variable, where binding used to turn it into `"`""
    Test-Assert ((ConvertTo-PkArgumentString $null) -eq '') "and takes `$null itself"
    Test-Assert ((ConvertTo-PkArgumentString 'two words') -eq '"two words"' -and (ConvertTo-PkArgumentString @(1, 'x y')) -eq '1 "x y"') "it still takes one string, and non-strings"

    # cmd.exe's special characters. A .bat/.cmd program runs through cmd.exe,
    # which acts on & | < > ^ outside quotes and splits batch arguments at , ;
    # so an element holding one is quoted even without a space.
    $special = @('a&b', 'a|b', 'a<b', 'a>b', 'a^b', '(x)', 'a,b', 'a;b')
    Test-Assert ((ConvertTo-PkArgumentString $special) -eq '"a&b" "a|b" "a<b" "a>b" "a^b" "(x)" "a,b" "a;b"') "an element with a cmd.exe special character is quoted"
    Test-Assert ((Get-BatchArgvText $special) -eq '[a&b][a|b][a<b][a>b][a^b][(x)][a,b][a;b]') "and an ordinary program still gets it exactly"
    Test-Assert ((ConvertTo-PkArgumentString @('a=b', '100%', 'a!b')) -eq 'a=b 100% a!b') "= % and ! are left alone"
    $batFile = Join-Path $env:TEMP ("pk-args-" + [guid]::NewGuid().ToString("N") + ".cmd")
    # set "NAME=value" keeps & | ^ literal, so this prints what cmd handed over.
    [System.IO.File]::WriteAllText($batFile, "@echo off`r`nset `"PKARG1=%~1`"`r`nset `"PKARG2=%~2`"`r`nset PKARG`r`n")
    foreach ($value in @('a&ver', 'a|b', 'a^b', 'a,b', 'a;b', '(x)')) {
        $batText = $null
        try { $batText = (Invoke-PkProcessWithTimeout -FilePath $batFile -Arguments @($value) -TimeoutMs 10000).Stdout.Trim() } catch { $batText = [string]$_ }
        Test-Assert ($batText -ceq ('PKARG1=' + $value)) ("a .cmd program gets '" + $value + "' as one argument, and nothing else runs (" + $batText + ")")
    }
    try { [System.IO.File]::Delete($batFile) } catch { }  # temp file only; best effort

    # A quote in a list element for a .bat/.cmd: cmd.exe counts every quote,
    # \" included, so with \" an element like a" & <command> & " runs that
    # command; the kit writes "" instead. The batch file does nothing, so only
    # cmd.exe's reading of the command line could create the marker. It's a
    # bare name in the working folder, so a space in %TEMP% can't send it
    # elsewhere and let the check pass anyway.
    $injDir = Join-Path $env:TEMP ("pk-inj-" + [guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Path $injDir
    $injMarker = Join-Path $injDir 'pk-marker.txt'
    $injBat = Join-Path $injDir 'noop.cmd'
    [System.IO.File]::WriteAllText($injBat, "@rem does nothing`r`n")
    $injPayloads = @('a" & echo x>pk-marker.txt & "', 'a"&echo x>pk-marker.txt&"', '"&echo x>pk-marker.txt', 'a\" & echo x>pk-marker.txt & \"', 'a\\" & echo x>pk-marker.txt & "', 'a"^&echo x>pk-marker.txt', 'a"""&echo x>pk-marker.txt&"""')
    $injHits = 0
    foreach ($payload in $injPayloads) {
        try { $null = Invoke-PkProcessWithTimeout -FilePath $injBat -Arguments @($payload) -WorkingDirectory $injDir -TimeoutMs 10000 } catch { Write-Host "  injection probe threw: $_" }
        if ([System.IO.File]::Exists($injMarker)) { $injHits++; [System.IO.File]::Delete($injMarker) }
    }
    Test-Assert ($injHits -eq 0) ("a quote in a list element can't make a .cmd program run another command (" + $injHits + " of " + $injPayloads.Count + " did)")
    $injUpper = Join-Path $injDir 'NOOP.BAT'
    [System.IO.File]::WriteAllText($injUpper, "@rem does nothing`r`n")
    $null = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = $injUpper; WorkingDirectory = $injDir; Arguments = @($injPayloads[0]) })
    Test-Assert (-not [System.IO.File]::Exists($injMarker)) "the same through the batch, for a .BAT in capitals"
    # Windows drops trailing dots and spaces from a file name, so 'noop.cmd.'
    # still goes through cmd.exe.
    try { $null = Invoke-PkProcessWithTimeout -FilePath ($injBat + '.') -Arguments @($injPayloads[0]) -WorkingDirectory $injDir -TimeoutMs 10000 } catch { Write-Host "  injection probe threw: $_" }
    Test-Assert (-not [System.IO.File]::Exists($injMarker)) "and for a .cmd path written with a trailing dot"

    # And a batch file that passes %* on to a program still gets every
    # argument to it exactly: the C runtime reads "" inside quotes as one quote.
    $fwdBat = Join-Path $injDir 'fwd.cmd'
    [System.IO.File]::WriteAllText($fwdBat, ('@"' + $argvExe + '" %*' + "`r`n"))
    $fwdArgs = @('say "hi"', 'a\"b', 'C:\dir with space\', 'a" & echo x & "', '""', '"', 'a\\"b', 'a&b', 'plain')
    $text = $null
    try { $text = Get-ArgvText (Invoke-PkProcessWithTimeout -FilePath $fwdBat -Arguments $fwdArgs -TimeoutMs 10000).Stdout } catch { $text = "threw: $_" }
    $fwdExpected = (@($fwdArgs | ForEach-Object { '[' + $_ + ']' }) -join '')
    Test-Assert ($text -ceq $fwdExpected) ("a .cmd that passes %* on gets the list through exactly (" + $text + ")")

    # cmd.exe itself given a list gets the same quoting: the program after /c
    # still gets the list exactly (spaces, quotes, trailing backslashes), and
    # no element can make cmd.exe run another command. Under any spelling of
    # cmd.exe's name.
    $text = $null
    try { $text = Get-ArgvText (Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments (@('/d', '/c', $argvExe) + $fwdArgs) -TimeoutMs 10000).Stdout } catch { $text = "threw: $_" }
    Test-Assert ($text -ceq $fwdExpected) ("cmd.exe /c given a list passes it on to the program exactly (" + $text + ")")
    $cmdHits = 0
    $cmdThrew = 0
    $cmdNames = @($cmdExe, 'cmd', 'CMD.EXE', ($cmdExe.ToUpperInvariant() + '.'))
    foreach ($cmdName in $cmdNames) {
        foreach ($payload in $injPayloads) {
            try { $null = Invoke-PkProcessWithTimeout -FilePath $cmdName -Arguments @('/d', '/c', 'echo', $payload) -WorkingDirectory $injDir -TimeoutMs 10000 } catch { $cmdThrew++; Write-Host "  injection probe threw: $_" }
            if ([System.IO.File]::Exists($injMarker)) { $cmdHits++; [System.IO.File]::Delete($injMarker) }
        }
    }
    Test-Assert ($cmdHits -eq 0 -and $cmdThrew -eq 0) ("a quote in a list element can't make cmd.exe /c run another command (" + $cmdHits + " of " + ($cmdNames.Count * $injPayloads.Count) + " did, " + $cmdThrew + " failed to run)")
    $cmdBatch = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = 'cmd.exe'; WorkingDirectory = $injDir; Arguments = @('/d', '/c', 'echo', $injPayloads[0]) })
    Test-Assert (-not [System.IO.File]::Exists($injMarker) -and $cmdBatch.Results[0].ExitCode -eq 0) "the same for cmd.exe through the batch"

    # A line break would end cmd.exe's command line and drop the rest, so it's
    # refused for a batch file, and still fine for any other program.
    $nlError = ''
    try { $null = Invoke-PkProcessWithTimeout -FilePath $fwdBat -Arguments @('a', ("b" + "`n" + "c")) -TimeoutMs 10000 } catch { $nlError = [string]$_ }
    $nlBatch = (Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = $fwdBat; Arguments = @(("b" + "`r" + "c")) })).Results[0]
    Test-Assert ($nlError -like '*element 2*line break*' -and [string]$nlBatch.StartError -like '*line break*') ("a line break in a list element for a .cmd is refused with a clear error (" + $nlError + ")")
    Test-Assert ((Get-BatchArgvText @(("b" + "`n" + "c"))) -eq ("[b" + "`n" + "c]")) "and still reaches an ordinary program"
    try { [System.IO.Directory]::Delete($injDir, $true) } catch { }  # temp folder only; best effort

    # A string is still exactly as written.
    Test-Assert ((Get-BatchArgvText '"C:\My Files\a.png" out.jxl') -eq $spacedText) "a string is still passed exactly as written"
    # List elements are values, not pieces of a command line.
    Test-Assert ((Get-BatchArgvText @('"two words"', 'x')) -eq '["two words"][x]') "quotes already in a list element reach the program as quotes"

    # The join doesn't follow $OFS.
    $OFS = ','
    try { $text = Get-BatchArgvText $spaced } finally { Remove-Variable -Name OFS }
    Test-Assert ($text -eq $spacedText) ("`$OFS doesn't change a list (" + $text + ")")

    # A hashtable is enumerable, but it isn't a list of arguments.
    Reset-Harness
    $hashBatch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $argvExe; Arguments = @{ a = 1 } }) -MaxConcurrent 1
    Test-Assert ($hashBatch.Results[0].StartError -like '*Arguments must be*' -and $null -eq $hashBatch.Results[0].ExitCode) "a hashtable in Arguments is that command's StartError"
    $thrown = $null
    try { $null = Invoke-PkProcessWithTimeout -FilePath $argvExe -Arguments @{ a = 1 } } catch { $thrown = [string]$_ }
    Test-Assert ($thrown -like '*Arguments must be*') "and a clear error from the direct functions"

    # A list inside the list is an error, not one argument.
    Reset-Harness
    $nestedBatch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $argvExe; Arguments = @('a', @('b', 'c')) }) -MaxConcurrent 1
    Test-Assert ($nestedBatch.Results[0].StartError -like '*element 2 is itself a list*' -and $null -eq $nestedBatch.Results[0].ExitCode) ("a list inside an Arguments list is that command's StartError (" + $nestedBatch.Results[0].StartError + ")")
    $thrown = $null
    try { $null = ConvertTo-PkArgumentString @('a', @{ b = 1 }) } catch { $thrown = [string]$_ }
    Test-Assert ($thrown -like '*element 2 is itself a list*') "and ConvertTo-PkArgumentString refuses one too, a hashtable included"

    # File and folder objects are their full path. On 5.1 a FileInfo from
    # Get-ChildItem casts to its bare name.
    $fsDir = Join-Path $env:TEMP ("pk fs " + [guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Force -Path $fsDir
    [System.IO.File]::WriteAllText((Join-Path $fsDir 'a b.txt'), 'x')
    $fsFile = Get-ChildItem -LiteralPath $fsDir -File
    $fsFolder = Get-Item -LiteralPath $fsDir
    $fsText = '[' + $fsFile.FullName + '][' + $fsFolder.FullName + ']'
    Test-Assert ((Get-BatchArgvText @($fsFile, $fsFolder)) -eq $fsText) ("Get-ChildItem and Get-Item objects in a list are their full paths (" + (Get-BatchArgvText @($fsFile, $fsFolder)) + ")")
    Test-Assert ((Get-BatchArgvText $fsFile) -eq ('[' + $fsFile.FullName + ']')) "and so is one on its own, quoted"
    Test-Assert ((ConvertTo-PkArgumentString @($fsFile)) -eq ('"' + $fsFile.FullName + '"')) "ConvertTo-PkArgumentString too"
    Remove-Item -LiteralPath $fsDir -Recurse -Force

    # Inside a worker, where the kit's functions are plain copies.
    Reset-Harness
    $argWorker = [System.Collections.Generic.List[object]]::new()
    $argOut = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Exe = $argvExe })) -ResultHandler { param($r) $argWorker.Add($r) }.GetNewClosure() -WorkerScript {
        param([string]$Exe)
        $batch = Invoke-PkProcessBatch -Commands @(@{ FilePath = $Exe; Arguments = @('two words', 'x') }) -MaxConcurrent 1
        return @{ Stdout = $batch.Results[0].Stdout; StartError = $batch.Results[0].StartError }
    }
    Test-Assert ($argOut.CrashedCount -eq 0 -and $argWorker.Count -eq 1 -and (Get-ArgvText $argWorker[0]['Stdout']) -eq '[two words][x]') "a list works inside a worker"
    try { [System.IO.File]::Delete($argvExe) } catch { }  # temp file only; best effort
}
Reset-Harness
Write-Host ""

Write-Host "=== AF: parameter handling: advanced functions, aliases, the safety switch ===" -ForegroundColor Cyan

# Every public function is advanced, so a wrong or extra argument is an error
# rather than silently ignored.
$simpleFunctions = @($publicFunctions | Where-Object { -not (Get-Command $_).CmdletBinding })
Test-Assert ($simpleFunctions.Count -eq 0) ("every public function rejects unknown arguments (not: " + ($simpleFunctions -join ', ') + ")")
$threw = $null
try { $null = Initialize-ParallelKit -MaxParallel 4 } catch { $threw = [string]$_ }
Test-Assert ($threw -like '*MaxParallel*') "Initialize-ParallelKit -MaxParallel (the engine's name) is an error, not ignored"
$threw = $null
try { $null = Test-PkAbortSignal 'extra' } catch { $threw = [string]$_ }
Test-Assert ($null -ne $threw) "Test-PkAbortSignal refuses an argument it doesn't take"
$threw = $null
try { Reset-PkAbortState -WhatIf } catch { $threw = [string]$_ }
Test-Assert ($null -ne $threw) "Reset-PkAbortState -WhatIf is an error, not a reset"
# Still called the usual ways.
Set-PkMessageHandler { param($Message, $Level) $messageSink.Add(@{ Message = $Message; Level = $Level }) }.GetNewClosure()
Write-PkMessage 'pk-positional-handler'
Test-Assert ((Get-StartMessageCount '*pk-positional-handler*') -eq 1) "Set-PkMessageHandler still takes the handler by position"

$threw = $null
try { $null = Invoke-PkProcessBatch -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) -MaxConcurrent 0 } catch { $threw = [string]$_ }
Test-Assert ($threw -like 'Invoke-PkProcessBatch:*') ("the batch's own -MaxConcurrent error names the batch (" + $threw + ")")

# The concurrency and abort-wait names work on every engine.
Reset-Harness
$aliasBatchParams = @{ Commands = @(@{ FilePath = $cmdExe; Arguments = '/c exit 3' }); MaxParallel = 2; DrainTimeoutSeconds = 5 }
$aliasBatch = $null
try { $aliasBatch = Invoke-PkProcessBatch @aliasBatchParams } catch { Write-Host "  batch alias threw: $_" }
Test-Assert ($null -ne $aliasBatch -and $aliasBatch.Results[0].ExitCode -eq 3) "the batch takes -MaxParallel and -DrainTimeoutSeconds"
$aliasRunParams = @{ WorkerScript = { param($Id) $Id * 2 }; JobParams = (New-JobList -Jobs @(@{ Id = 21 })); MaxConcurrent = 2; AbortTimeoutSeconds = 5 }
$aliasRunResults = [System.Collections.Generic.List[object]]::new()
try { $null = Invoke-PkRunspaceJobs @aliasRunParams -ResultHandler { param($r) $aliasRunResults.Add($r) }.GetNewClosure() } catch { Write-Host "  runspace alias threw: $_" }
Test-Assert ($aliasRunResults.Count -eq 1 -and $aliasRunResults[0] -eq 42) "Invoke-PkRunspaceJobs takes -MaxConcurrent and -AbortTimeoutSeconds"
$aliasFeed = @{ Given = $false }
$aliasDispatch = $null
try {
    $aliasDispatch = Invoke-PkProcessDispatch -MaxParallel 1 -DrainTimeoutSeconds 5 `
        -GroupProvider { if ($aliasFeed.Given) { return $null }; $aliasFeed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure() `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job }
} catch { Write-Host "  dispatcher alias threw: $_" }
Test-Assert ($null -ne $aliasDispatch -and $aliasDispatch.GroupResults.Count -eq 1) "the dispatcher takes -MaxParallel and -DrainTimeoutSeconds"

# -CheckWorkerSafety: on unless turned off, however it's passed.
$unsafeWorker = { param($Id) $null = [Func[int]]{ 1 } }
$threw = $false
try { $null = Invoke-PkRunspaceJobs -WorkerScript $unsafeWorker -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 } catch { $threw = ($_.ToString() -like '*Func*') }
Test-Assert $threw "the worker-safety check is on when -CheckWorkerSafety isn't given"
$safetyOff = @{ CheckWorkerSafety = $false }
$out = $null
try { $out = Invoke-PkRunspaceJobs -WorkerScript $unsafeWorker -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -MaxParallel 1 @safetyOff } catch { Write-Host "  splatted opt-out threw: $_" }
Test-Assert ($null -ne $out -and $out.CrashedCount -eq 0) "a splatted CheckWorkerSafety = `$false turns it off"
Reset-Harness
Write-Host ""

Write-Host "=== AG: a stopped run leaves no programs running ===" -ForegroundColor Cyan

# PowerShell stopping a script (Ctrl+C outside Invoke-PkRun, a third press
# inside it, the runspace engine force-stopping a worker) skips catch blocks
# and runs only finally blocks. Each run below is stopped while its programs
# are running; each uses its own ping count so it can be told apart.
$stopKitPath = Join-Path $PSScriptRoot "ParallelKit.ps1"
function Stop-StrayPings {
    param([int]$N)
    Get-LimitPing $N | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Invoke-StoppedRun {
    # Runs $Script (given the kit's path, then $ArgumentList) in its own
    # [PowerShell], waits for $Expect pings of count $N, stops it, and
    # returns how many were running before and after the stop.
    param([scriptblock]$Script, [object[]]$ArgumentList = @(), [int]$N, [int]$Expect)
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($Script).AddArgument($stopKitPath)
    foreach ($a in $ArgumentList) { $null = $ps.AddArgument($a) }
    $null = $ps.BeginInvoke()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Get-LimitPingCount $N) -lt $Expect -and $sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
    $before = Get-LimitPingCount $N
    $ps.Stop()
    $sw.Restart()
    while ((Get-LimitPingCount $N) -gt 0 -and $sw.Elapsed.TotalSeconds -lt 3) { Start-Sleep -Milliseconds 200 }
    $after = Get-LimitPingCount $N
    Stop-StrayPings $N
    $ps.Dispose()
    return @{ Before = $before; After = $after }
}

$stopRun = Invoke-StoppedRun -N 41 -Expect 2 -Script {
    param($kit, $ping)
    . $kit
    Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(@{ FilePath = $ping; Arguments = '-n 41 127.0.0.1' }, @{ FilePath = $ping; Arguments = '-n 41 127.0.0.1' })
} -ArgumentList @($pingExe)
Test-Assert ($stopRun.Before -eq 2 -and $stopRun.After -eq 0) ("stopping a batch kills its running programs (" + $stopRun.Before + " running, " + $stopRun.After + " left)")

$stopBudget = [System.Threading.SemaphoreSlim]::new(2, 2)
$stopRun = Invoke-StoppedRun -N 42 -Expect 2 -Script {
    param($kit, $ping, $budget)
    . $kit
    $feed = @{ Given = $false }
    Invoke-PkProcessDispatch -MaxConcurrent $budget `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $ping; Arguments = '-n 42 127.0.0.1' }, @{ FilePath = $ping; Arguments = '-n 42 127.0.0.1' }) }.GetNewClosure() `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job }
} -ArgumentList @($pingExe, $stopBudget)
Test-Assert ($stopRun.Before -eq 2 -and $stopRun.After -eq 0 -and $stopBudget.CurrentCount -eq 2) ("stopping a dispatcher kills its programs and gives back its shared slots (" + $stopRun.After + " left, " + $stopBudget.CurrentCount + " of 2 slots free)")

# Stopped while -JobStarter is still running, after it set .Proc: the job
# isn't in the running list yet.
$stopBudget = [System.Threading.SemaphoreSlim]::new(2, 2)
$stopRun = Invoke-StoppedRun -N 44 -Expect 1 -Script {
    param($kit, $ping, $budget)
    . $kit
    $feed = @{ Given = $false }
    Invoke-PkProcessDispatch -MaxConcurrent $budget `
        -GroupProvider { if ($feed.Given) { return $null }; $feed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $ping; Arguments = '-n 44 127.0.0.1' }) }.GetNewClosure() `
        -JobStarter { param($job) $s = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments']; $job['Proc'] = $s.Proc; $job['StdoutTask'] = $s.StdoutTask; $job['StderrTask'] = $s.StderrTask; Start-Sleep -Seconds 60; return $job } `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job }
} -ArgumentList @($pingExe, $stopBudget)
Test-Assert ($stopRun.Before -eq 1 -and $stopRun.After -eq 0 -and $stopBudget.CurrentCount -eq 2) ("stopping a dispatcher mid-start kills that program too and gives back its slot (" + $stopRun.After + " left, " + $stopBudget.CurrentCount + " of 2 slots free)")

$stopRun = Invoke-StoppedRun -N 43 -Expect 1 -Script {
    param($kit, $ping)
    . $kit
    Invoke-PkProcessWithTimeout -FilePath $ping -Arguments '-n 43 127.0.0.1' -TimeoutMs 120000
} -ArgumentList @($pingExe)
Test-Assert ($stopRun.Before -eq 1 -and $stopRun.After -eq 0) ("stopping Invoke-PkProcessWithTimeout kills its program (" + $stopRun.Before + " running, " + $stopRun.After + " left)")

# The runspace engine force-stops a worker whose dispatcher is still waiting
# out its own abort: the worker's programs must die with it.
Reset-Harness
$stopCts = [System.Threading.CancellationTokenSource]::new()
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
$stopPoll = { if ($stopWatch.Elapsed.TotalSeconds -ge 1 -and (Get-LimitPingCount 46) -ge 2) { $stopCts.Cancel() } elseif ($stopWatch.Elapsed.TotalSeconds -ge 15) { $stopCts.Cancel() } }.GetNewClosure()
$stopOut = $null
try {
    $stopOut = Invoke-PkRunspaceJobs -MaxParallel 1 -Cts $stopCts -DrainTimeoutSeconds 1 -AbortWaitMessage '' -PollCallback $stopPoll `
        -JobParams (New-JobList -Jobs @(@{ Ping = $pingExe })) `
        -WorkerScript { param($Ping) $null = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(@{ FilePath = $Ping; Arguments = '-n 46 127.0.0.1' }, @{ FilePath = $Ping; Arguments = '-n 46 127.0.0.1' }) }
} catch { Write-Host "  force-stopped worker run threw: $_" }
$stopWatch.Restart()
while ((Get-LimitPingCount 46) -gt 0 -and $stopWatch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 200 }
$stopLeft = Get-LimitPingCount 46
Stop-StrayPings 46
Test-Assert ($null -ne $stopOut -and $stopOut.ForceStoppedCount -eq 1 -and $stopLeft -eq 0) ("a force-stopped worker's programs are killed (" + $stopLeft + " left)")
$stopCts.Dispose()

# Not a stop, but the same leak: a starter that started its program and then
# threw. The failed start is counted and reported; the program must not run on.
Reset-Harness
$stopBudget = [System.Threading.SemaphoreSlim]::new(2, 2)
$stopFeed = @{ Given = $false }
$stopResult = $null
try {
    $stopResult = Invoke-PkProcessDispatch -MaxConcurrent $stopBudget `
        -GroupProvider { if ($stopFeed.Given) { return $null }; $stopFeed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return @(@{ FilePath = $pingExe; Arguments = '-n 48 127.0.0.1' }) }.GetNewClosure() `
        -JobStarter { param($job) $s = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments']; $job['Proc'] = $s.Proc; throw "starter failed after starting" } `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job }
} catch { Write-Host "  throwing-starter run threw: $_" }
$stopLeft = Get-LimitPingCount 48
Stop-StrayPings 48
Test-Assert ($null -ne $stopResult -and $stopResult.JobStarterFailedCount -eq 1 -and $stopLeft -eq 0 -and $stopBudget.CurrentCount -eq 2) ("a starter that throws after starting its program doesn't leave it running (" + $stopLeft + " left, " + $stopBudget.CurrentCount + " of 2 slots free)")

# An error out of the loop, after another job in the same pass was finalized
# and disposed: the teardown must still kill the job that's running.
Reset-Harness
$stopJobs = @(@{ Name = 'a'; FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ Name = 'b'; FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ Name = 'c'; FilePath = $pingExe; Arguments = '-n 47 127.0.0.1' })
$stopFeed = @{ Given = $false }
$stopReady = @{ Done = $false }
$stopProblem = $null
try {
    $null = Invoke-PkProcessDispatch -MaxConcurrent 3 `
        -GroupProvider { if ($stopFeed.Given) { return $null }; $stopFeed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return $stopJobs }.GetNewClosure() `
        -JobPollCompleted {
            param($job)
            if ($job['Name'] -eq 'c') { return $false }
            # 'a' and 'b' only report done together, so both finish in one
            # pass. Latched: 'a' is disposed once it's finalized.
            if (-not $stopReady.Done) {
                foreach ($j in $stopJobs[0..1]) { if ($null -eq $j['Proc'] -or -not $j['Proc'].HasExited) { return $false } }
                if ((Get-LimitPingCount 47) -lt 1) { return $false }
                $stopReady.Done = $true
            }
            return $true
        }.GetNewClosure() `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job; if ($job['Name'] -eq 'b') { throw "finalize failed" } }
} catch { $stopProblem = [string]$_ }
$stopLeft = Get-LimitPingCount 47
Stop-StrayPings 47
Test-Assert ($stopProblem -like '*finalize failed*' -and $stopLeft -eq 0) ("an error after a job was finalized in the same pass still kills the running ones (" + $stopLeft + " left, problem: " + $stopProblem + ")")

# A -JobFinalize that disposes the job's process and then throws: the
# teardown's kill list then holds a disposed Process, whose HasExited and Id
# read as $null. It mustn't spoil the kill for the jobs still running.
Reset-Harness
$dispJobs = @(1..3 | ForEach-Object { @{ Name = ('p' + $_); FilePath = $cmdExe; Arguments = ('/c ""' + $pingExe + '" -n 51 127.0.0.1"') } })
$dispJobs += @{ Name = 'a'; FilePath = $cmdExe; Arguments = '/c exit 0' }
$dispFeed = @{ Given = $false }
$dispWaitStart = [System.Diagnostics.Stopwatch]::StartNew()
$dispProblem = $null
try {
    $null = Invoke-PkProcessDispatch -MaxConcurrent 4 `
        -GroupProvider { if ($dispFeed.Given) { return $null }; $dispFeed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return $dispJobs }.GetNewClosure() `
        -JobPollCompleted {
            param($job)
            # 'a' reports done once the three pings run (bounded, so a ping
            # that never starts fails the test instead of hanging it).
            if ($job['Name'] -ne 'a') { return $false }
            return ($job['Proc'].HasExited -and ((Get-LimitPingCount 51) -ge 3 -or $dispWaitStart.Elapsed.TotalSeconds -gt 15))
        }.GetNewClosure() `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job -Dispose; throw "finalize failed after dispose" }
} catch { $dispProblem = [string]$_ }
$dispLeft = Get-LimitPingCount 51
Stop-StrayPings 51
Test-Assert ($dispProblem -like '*finalize failed after dispose*' -and $dispLeft -eq 0) ("a -JobFinalize that disposes its process and throws still has the running jobs killed (" + $dispLeft + " of 3 left, problem: " + $dispProblem + ")")

# The same directly: a disposed process in the list doesn't stop the live
# tree beside it being killed.
$dispGone = Start-PkProcess -FilePath $cmdExe -Arguments '/c exit 0'
$null = Wait-PkProcess -Process $dispGone.Proc -TimeoutMs 5000
$dispGone.Proc.Dispose()
$dispLive = Start-PkProcess -FilePath $cmdExe -Arguments ('/c ""' + $pingExe + '" -n 53 127.0.0.1"')
$dispWait = [System.Diagnostics.Stopwatch]::StartNew()
while ((Get-LimitPingCount 53) -lt 1 -and $dispWait.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
$dispThrew = $null
$dispKilled = $false
try { $dispKilled = Stop-PkProcessTree -Process @($dispGone.Proc, $dispLive.Proc) } catch { $dispThrew = [string]$_ }
$dispLeft = Get-LimitPingCount 53
Stop-StrayPings 53
Test-Assert ($null -eq $dispThrew -and $dispKilled -and $dispLeft -eq 0 -and $dispLive.Proc.HasExited) ("Stop-PkProcessTree kills a live tree listed beside a disposed process (" + $dispLeft + " left, returned " + $dispKilled + ", threw: " + $dispThrew + ")")
try { if (-not $dispLive.Proc.HasExited) { $dispLive.Proc.Kill() } } catch { }  # cleanup after a failure; already-exited is fine
$dispLive.Proc.Dispose()

# A -JobFinalize that throws: the job it was finalizing had finished, so the
# teardown must not call -JobAbortCleanup on it (that deletes a killed job's
# partial output), only on the job it kills. Both slots still come back.
Reset-Harness
$fcJobs = @(@{ Name = 'run'; FilePath = $cmdExe; Arguments = ('/c ""' + $pingExe + '" -n 55 127.0.0.1"') }, @{ Name = 'done'; FilePath = $cmdExe; Arguments = '/c exit 0' })
$fcFeed = @{ Given = $false }
$fcCleaned = [System.Collections.Generic.List[string]]::new()
$fcBudget = [System.Threading.SemaphoreSlim]::new(2, 2)
$fcWait = [System.Diagnostics.Stopwatch]::StartNew()
$fcProblem = $null
try {
    $null = Invoke-PkProcessDispatch -MaxConcurrent $fcBudget `
        -GroupProvider { if ($fcFeed.Given) { return $null }; $fcFeed.Given = $true; return 'g' }.GetNewClosure() `
        -JobBuilder { param($g) return $fcJobs }.GetNewClosure() `
        -JobPollCompleted {
            param($job)
            if ($job['Name'] -ne 'done') { return $false }
            return ($job['Proc'].HasExited -and ((Get-LimitPingCount 55) -ge 1 -or $fcWait.Elapsed.TotalSeconds -gt 15))
        }.GetNewClosure() `
        -JobFinalize { param($job, $q) $null = Complete-PkProcess -Job $job; throw "finalize failed" } `
        -JobAbortCleanup { param($job) $fcCleaned.Add($job['Name']) }.GetNewClosure()
} catch { $fcProblem = [string]$_ }
$fcLeft = Get-LimitPingCount 55
Stop-StrayPings 55
Test-Assert ($fcProblem -like '*finalize failed*' -and ($fcCleaned -join ',') -eq 'run' -and $fcLeft -eq 0 -and $fcBudget.CurrentCount -eq 2) ("a -JobFinalize that throws gets no -JobAbortCleanup for its finished job, only for the killed one (cleaned: " + ($fcCleaned -join ',') + ", " + $fcLeft + " left, " + $fcBudget.CurrentCount + " of 2 slots free)")

# A -JobPollCompleted that leaks a value (ArrayList.Add returns the index)
# before its answer: only the last value counts, so the job isn't finalized
# while its program still runs.
Reset-Harness
$leakSeen = [System.Collections.ArrayList]::new()
$leakFin = @{ Count = 0; Exited = $null }
$leakFeed = @{ Given = $false }
$null = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($leakFeed.Given) { return $null }; $leakFeed.Given = $true; return 'g' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $pingExe; Arguments = '-n 2 127.0.0.1' }) }.GetNewClosure() `
    -JobPollCompleted { param($job) $leakSeen.Add(1); $job['Proc'].HasExited }.GetNewClosure() `
    -JobFinalize { param($job, $q) $leakFin.Count++; $leakFin.Exited = $job['Proc'].HasExited; $null = Complete-PkProcess -Job $job }.GetNewClosure()
Test-Assert ($leakFin.Count -eq 1 -and $leakFin.Exited -eq $true -and $leakSeen.Count -gt 1) ("a -JobPollCompleted that leaks a value finalizes the job only once it has exited (finalized " + $leakFin.Count + "x, HasExited then: " + $leakFin.Exited + ", polled " + $leakSeen.Count + "x)")
Reset-Harness
Write-Host ""

Write-Host "=== AH: 'continue' or 'break' in a callback stays in the callback ===" -ForegroundColor Cyan

# PowerShell sends continue/break to the nearest loop on the call stack, which
# for a callback is one of the kit's own. Each case runs in its own
# [PowerShell] so one that hangs fails after a timeout instead of hanging the
# suite. In each, KEYWORD becomes the keyword; the case sets $kwOk and
# $kwDetail. The kit must finish the run correctly and warn once.
$kwPrelude = @'
$kwMessages = [System.Collections.Generic.List[string]]::new()
Set-PkMessageHandler { param($Message, $Level) $kwMessages.Add($Message) }.GetNewClosure()
$kwCount = @{ N = 0 }
$kwList = [System.Collections.Generic.List[object]]::new()
function Invoke-KwDispatch {
    param([hashtable]$Extra = @{}, [int]$Jobs = 2, [string]$FilePath = 'cmd.exe', [string]$Arguments = '/c exit 0', [int]$MaxConcurrent = 1)
    $feed = @{ Given = $false }
    $done = [System.Collections.Generic.List[object]]::new()
    $p = @{
        MaxConcurrent = $MaxConcurrent
        GroupProvider = { if ($feed.Given) { return $null }; $feed.Given = $true; 'g' }.GetNewClosure()
        JobBuilder    = { param($g) foreach ($i in 1..$Jobs) { @{ FilePath = $FilePath; Arguments = $Arguments } } }.GetNewClosure()
        JobFinalize   = { param($job, $q) $null = Complete-PkProcess -Job $job; $done.Add(1) }.GetNewClosure()
    }
    foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
    $r = Invoke-PkProcessDispatch @p
    return @{ Result = $r; Done = $done.Count }
}
'@
$kwCases = [ordered]@{
    '-OnComplete (batch)' = @'
$b = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = 'cmd.exe'; Arguments = '/c exit 0' }, @{ FilePath = 'cmd.exe'; Arguments = '/c exit 0' }, @{ FilePath = 'cmd.exe'; Arguments = '/c exit 0' }) -OnComplete { param($c, $r) $kwCount.N++; KEYWORD }
$kwOk = ($b.Results.Count -eq 3 -and $kwCount.N -eq 3); $kwDetail = "results " + $b.Results.Count + ", calls " + $kwCount.N
'@
    '-JobFinalize' = @'
$d = Invoke-KwDispatch -Extra @{ JobFinalize = { param($job, $q) $null = Complete-PkProcess -Job $job; $kwCount.N++; KEYWORD } }
$kwOk = ($kwCount.N -eq 2 -and $d.Result.GroupResults.Count -eq 1 -and $d.Result.GroupResults[0].Completed); $kwDetail = "finalized " + $kwCount.N
'@
    '-GroupCompleteCallback' = @'
$d = Invoke-KwDispatch -Extra @{ GroupCompleteCallback = { param($g) $kwCount.N++; KEYWORD } }
$kwOk = ($kwCount.N -eq 1 -and $d.Done -eq 2 -and $d.Result.GroupResults.Count -eq 1); $kwDetail = "calls " + $kwCount.N + ", done " + $d.Done
'@
    '-JobStarter' = @'
$d = Invoke-KwDispatch -Extra @{ JobStarter = { param($job) $s = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments']; $job['Proc'] = $s.Proc; $job['StdoutTask'] = $s.StdoutTask; $job['StderrTask'] = $s.StderrTask; KEYWORD } }
$kwOk = ($d.Done -eq 2 -and $d.Result.JobStarterFailedCount -eq 0); $kwDetail = "done " + $d.Done
'@
    '-JobPollCompleted' = @'
$d = Invoke-KwDispatch -FilePath 'ping.exe' -Arguments '-n 2 127.0.0.1' -MaxConcurrent 2 -Extra @{ JobPollCompleted = { param($job) if ($job['Proc'].HasExited) { return $true }; $kwCount.N++; KEYWORD } }
$kwOk = ($d.Done -eq 2 -and $kwCount.N -gt 0); $kwDetail = "done " + $d.Done + ", not-yet polls " + $kwCount.N
'@
    '-JobAbortCleanup' = @'
$cts = [System.Threading.CancellationTokenSource]::new()
$cts.CancelAfter(300)
$d = Invoke-KwDispatch -Jobs 3 -FilePath 'ping.exe' -Arguments '-n 2 127.0.0.1' -Extra @{ CancelToken = $cts.Token; AbortTimeoutSeconds = 30; JobAbortCleanup = { param($job) $kwCount.N++; KEYWORD } }
$kwOk = ($d.Result.Aborted -and $d.Done -eq 1 -and $kwCount.N -eq 2); $kwDetail = "done " + $d.Done + ", cleaned " + $kwCount.N
'@
    '-JobFinalize (abort wait)' = @'
$cts = [System.Threading.CancellationTokenSource]::new()
$cts.CancelAfter(300)
$d = Invoke-KwDispatch -Jobs 3 -FilePath 'ping.exe' -Arguments '-n 2 127.0.0.1' -Extra @{ CancelToken = $cts.Token; AbortTimeoutSeconds = 30; JobFinalize = { param($job, $q) $null = Complete-PkProcess -Job $job; $kwCount.N++; KEYWORD } }
$kwOk = ($d.Result.Aborted -and $kwCount.N -eq 1 -and $d.Result.ForceKilledCount -eq 0); $kwDetail = "finalized " + $kwCount.N + ", force-killed " + $d.Result.ForceKilledCount
'@
    '-JobPollCompleted (abort wait)' = @'
$cts = [System.Threading.CancellationTokenSource]::new()
$cts.CancelAfter(300)
$d = Invoke-KwDispatch -Jobs 3 -FilePath 'ping.exe' -Arguments '-n 2 127.0.0.1' -Extra @{ CancelToken = $cts.Token; AbortTimeoutSeconds = 30; JobPollCompleted = { param($job) if ($job['Proc'].HasExited) { return $true }; $kwCount.N++; KEYWORD } }
$kwOk = ($d.Result.Aborted -and $d.Done -eq 1 -and $d.Result.ForceKilledCount -eq 0); $kwDetail = "done " + $d.Done + ", force-killed " + $d.Result.ForceKilledCount
'@
    '-GroupReleaseCheck' = @'
$d = Invoke-KwDispatch -Jobs 0 -Extra @{ JobBuilder = { param($g) }; GroupReleaseCheck = { param($g) $kwCount.N++; if ($kwCount.N -ge 3) { return $true }; KEYWORD } }
$kwOk = ($d.Result.GroupResults.Count -eq 1 -and $kwCount.N -ge 3); $kwDetail = "checks " + $kwCount.N
'@
    '-PollCallback (dispatcher)' = @'
$d = Invoke-KwDispatch -Extra @{ PollCallback = { param($running) $kwCount.N++; KEYWORD } }
$kwOk = ($d.Done -eq 2 -and $d.Result.GroupResults.Count -eq 1); $kwDetail = "done " + $d.Done
'@
    '-GroupProvider' = @'
$d = Invoke-KwDispatch -Extra @{ GroupProvider = { $kwCount.N++; if ($kwCount.N -eq 1) { return 'g' }; KEYWORD } }
$kwOk = ($d.Done -eq 2 -and $d.Result.GroupResults.Count -eq 1); $kwDetail = "done " + $d.Done + ", provider calls " + $kwCount.N
'@
    '-JobBuilder' = @'
$d = Invoke-KwDispatch -Extra @{ JobBuilder = { param($g) @{ FilePath = 'cmd.exe'; Arguments = '/c exit 0' }; KEYWORD } }
$kwOk = ($d.Done -eq 1 -and $d.Result.GroupResults.Count -eq 1); $kwDetail = "done " + $d.Done
'@
    '-ResultHandler' = @'
$o = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Id = 1 }) -WorkerScript { param($Id) 1; 2; 3 } -ResultHandler { param($r) $kwCount.N++; KEYWORD }
$kwOk = ($kwCount.N -eq 3 -and -not $o.Aborted); $kwDetail = "results " + $kwCount.N
'@
    '-PollCallback' = @'
$o = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -WorkerScript { param($Id) Start-Sleep -Milliseconds 300; $Id } -ResultHandler { param($r) $kwList.Add($r) } -PollCallback { $kwCount.N++; KEYWORD }
$kwOk = ($kwList.Count -eq 2 -and $o.ForceStoppedCount -eq 0); $kwDetail = "results " + $kwList.Count
'@
    '-NextJobProvider' = @'
$o = Invoke-PkRunspaceJobs -MaxParallel 1 -NextJobProvider { $kwCount.N++; if ($kwCount.N -le 3) { return @{ Id = $kwCount.N } }; KEYWORD } -WorkerScript { param($Id) $Id } -ResultHandler { param($r) $kwList.Add($r) }
$kwOk = ($kwList.Count -eq 3); $kwDetail = "results " + $kwList.Count
'@
    '-JobCrashedHandler' = @'
$o = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -WorkerScript { param($Id) throw "boom" } -JobCrashedHandler { param($e) $kwCount.N++; KEYWORD }
$kwOk = ($kwCount.N -eq 2 -and $o.CrashedCount -eq 2); $kwDetail = "handler calls " + $kwCount.N + ", crashed " + $o.CrashedCount
'@
    'message handler' = @'
Set-PkMessageHandler { param($Message, $Level) $kwList.Add($Message); KEYWORD }
$b = Invoke-PkProcessBatch -MaxConcurrent 1 -Commands @(@{ FilePath = 'cmd.exe'; Arguments = '/c exit 0' }, @{ FilePath = 'pk-no-such-program.exe' }, @{ FilePath = 'pk-no-such-other.exe' }, @{ FilePath = 'cmd.exe'; Arguments = '/c exit 0' })
$kwOk = ($b.Results.Count -eq 4 -and $kwList.Count -ge 2); $kwDetail = "results " + $b.Results.Count + ", messages " + $kwList.Count
'@
}
$kwEpilogue = @'
$kwWarnings = @($kwMessages | Where-Object { $_ -like "*'continue' or 'break'*" })
[pscustomobject]@{ Ok = [bool]$kwOk; Detail = [string]$kwDetail; Warned = $kwWarnings.Count; Text = ($kwWarnings -join ' | ') }
'@
$kwSavedHandler = [PkState]::MessageHandler
foreach ($kwName in $kwCases.Keys) {
    foreach ($kwKeyword in 'continue', 'break') {
        $kwScript = ". '" + $stopKitPath + "'`r`n" + $kwPrelude + "`r`n" + $kwCases[$kwName].Replace('KEYWORD', $kwKeyword) + "`r`n" + $kwEpilogue
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($kwScript)
        $async = $ps.BeginInvoke()
        $kwFinished = $async.AsyncWaitHandle.WaitOne(20000)
        $kwOut = $null
        $kwError = ''
        if ($kwFinished) {
            try { $kwOut = @($ps.EndInvoke($async)) | Select-Object -Last 1 } catch { $kwError = [string]$_ }
        } else {
            $ps.Stop()
        }
        $kwConsole = (@($ps.Streams.Information) | ForEach-Object { [string]$_ }) -join ' '
        $ps.Dispose()
        # The case set its own handler in this process's shared state: put the harness's back.
        [PkState]::MessageHandler = $kwSavedHandler
        if ($kwName -eq 'message handler') {
            # Its warning can't go through the handler that broke, so it goes
            # to the console, once however many messages the handler got.
            $kwWarned = ([regex]::Matches($kwConsole, "'continue' or 'break'")).Count -eq 1
        } else {
            # The warning names the parameter and the engine it was given to.
            $kwEngine = 'ProcessDispatch'
            if ($kwName -like '*(batch)') { $kwEngine = 'Invoke-PkProcessBatch' }
            elseif ($kwName -in '-ResultHandler', '-PollCallback', '-NextJobProvider', '-JobCrashedHandler') { $kwEngine = 'Invoke-PkRunspaceJobs' }
            $kwExpected = $kwEngine + ': ' + ($kwName -split ' ')[0] + " used 'continue' or 'break'"
            $kwWarned = ($null -ne $kwOut -and $kwOut.Warned -eq 1 -and $kwOut.Text.StartsWith($kwExpected))
        }
        $kwDetailText = if ($null -ne $kwOut) { $kwOut.Detail + ", warnings " + $kwOut.Warned + ": " + $kwOut.Text } elseif ($kwFinished) { "error: " + $kwError } else { "still running after 20 s" }
        Test-Assert ($kwFinished -and $null -ne $kwOut -and $kwOut.Ok -and $kwWarned) ("'" + $kwKeyword + "' in " + $kwName + " ends only the callback, with one warning (" + $kwDetailText + ")")
    }
}

# The wrap hands back what a callback returned as it was: a one-element
# array returned whole (`,@(...)`) is still that array.
Reset-Harness
$kwFeed = @{ Given = $false }
$kwShape = $null
$kwRun = Invoke-PkProcessDispatch -MaxConcurrent 1 `
    -GroupProvider { if ($kwFeed.Given) { return $null }; $kwFeed.Given = $true; return ,@('only') }.GetNewClosure() `
    -JobBuilder { param($g) return @() } `
    -GroupCompleteCallback { param($g) $kwFeed.Shape = $g.GetType().Name + ':' + @($g).Count }.GetNewClosure() `
    -JobFinalize { param($job, $q) }
$kwShape = $kwFeed['Shape']
Test-Assert ($kwShape -eq 'Object[]:1' -and $kwRun.GroupResults[0].GroupInfo -is [array]) ("a group returned whole as a one-element array stays an array (" + $kwShape + ")")

# A labeled break to the caller's own loop leaves the call: it stops there
# and kills its programs.
$kwLabeled = 'unset'
:kwOuter foreach ($kwI in 1..1) {
    $kwLabeled = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }, @{ FilePath = $pingExe; Arguments = '-n 35 127.0.0.1' }) -OnComplete { param($c, $r) break kwOuter }
}
$kwLeft = Get-LimitPingCount 35
Stop-StrayPings 35
Test-Assert ($kwLabeled -eq 'unset' -and $kwLeft -eq 0) ("a labeled break out of a callback leaves the call and kills its programs (" + $kwLeft + " left)")
Reset-Harness
Write-Host ""

Write-Host "=== AI: a worker's non-terminating errors are recorded with their job ===" -ForegroundColor Cyan

Reset-Harness
$errOut = [System.Collections.Generic.List[object]]::new()
$errRun = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams (New-JobList -Jobs @(@{ Id = 1 }, @{ Id = 2 }, @{ Id = 3 })) -WorkerScript {
    param([int]$Id)
    if ($Id -eq 2) { Write-Error "soft two"; Write-Error "soft two again" }
    return $Id
} -ResultHandler { param($r) $errOut.Add($r) }.GetNewClosure()
$errProp = $errRun.PSObject.Properties['Errors']   # read safely: strict mode throws on a missing property
$errList = @()
if ($null -ne $errProp) { $errList = @($errProp.Value) }
$errOk = ($errList.Count -eq 2)
foreach ($e in $errList) { if ($e.Job['Id'] -ne 2 -or $e.Error -isnot [System.Management.Automation.ErrorRecord] -or ([string]$e.Error) -notlike 'soft two*') { $errOk = $false } }
Test-Assert ($errOk -and $errRun.CrashedCount -eq 0 -and $errOut.Count -eq 3) ("a worker's non-terminating errors land in Errors, each with its job and ErrorRecord (" + $errList.Count + " entries)")
$errPrinted = @($script:messages | Where-Object { $_.Level -eq 'Error' -and $_.Message -like 'Runspace error: soft two*' }).Count
Test-Assert ($errPrinted -eq 2) ("and are still printed (" + $errPrinted + ")")

# A worker that writes an error and then throws: the error it wrote is
# printed and recorded too, and the throw is a crash, not an Errors entry.
Reset-Harness
$errRun = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 7 })) -WorkerScript {
    param([int]$Id)
    Write-Error "soft before the crash"
    throw "hard crash"
}
$errProp = $errRun.PSObject.Properties['Errors']
$errList = @()
if ($null -ne $errProp) { $errList = @($errProp.Value) }
$errPrinted = @($script:messages | Where-Object { $_.Message -like 'Runspace error: soft before the crash*' }).Count
Test-Assert ($errRun.CrashedCount -eq 1 -and $errList.Count -eq 1 -and $errList[0].Job['Id'] -eq 7 -and ([string]$errList[0].Error) -like 'soft before the crash*' -and $errPrinted -eq 1) ("a crashed worker's earlier non-terminating error is printed and recorded (" + $errList.Count + " entries, printed " + $errPrinted + ")")

# An empty job list returns the same shape.
$errEmpty = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @() -WorkerScript { param($Id) }
$errProp = $errEmpty.PSObject.Properties['Errors']
Test-Assert ($null -ne $errProp -and @($errProp.Value).Count -eq 0) "an empty run has an empty Errors list"
Reset-Harness
Write-Host ""

Write-Host "=== AJ: a tree kill counts a program it killed, even if taskkill reports failure ===" -ForegroundColor Cyan

# taskkill /T exits non-zero when any process in the tree couldn't be killed,
# even though the program itself was. A child that refuses PROCESS_TERMINATE
# (its DACL denies it) makes that happen every time. The Job Object still
# ends it when this process exits, and it's a short ping anyway. An elevated
# taskkill may ignore the DACL; then the child dies too, and the check below
# still holds but doesn't exercise the failure path (the message says so).
if (-not ([System.Management.Automation.PSTypeName]'PkHarnessProcSec').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
public static class PkHarnessProcSec {
    [DllImport("advapi32.dll")]
    static extern uint SetSecurityInfo(IntPtr handle, int objectType, uint securityInfo, IntPtr owner, IntPtr group, byte[] dacl, IntPtr sacl);
    // Everyone: everything but PROCESS_TERMINATE. Returns the Win32 error, 0 = done.
    public static uint DenyTerminate(IntPtr handle) {
        var everyone = new SecurityIdentifier(WellKnownSidType.WorldSid, null);
        var dacl = new RawAcl(2, 2);
        dacl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessAllowed, 0x1FFFFE, everyone, false, null));
        dacl.InsertAce(0, new CommonAce(AceFlags.None, AceQualifier.AccessDenied, 0x0001, everyone, false, null));
        byte[] bytes = new byte[dacl.BinaryLength];
        dacl.GetBinaryForm(bytes, 0);
        return SetSecurityInfo(handle, 6 /* SE_KERNEL_OBJECT */, 4 /* DACL_SECURITY_INFORMATION */, IntPtr.Zero, IntPtr.Zero, bytes, IntPtr.Zero);
    }
}
'@
}
function Protect-HarnessPingChild {
    # Waits for the ping that $Parent started and makes it refuse to be
    # terminated. Returns its Process, or $null if it couldn't.
    param([System.Diagnostics.Process]$Parent)
    $child = $null
    for ($i = 0; $i -lt 50 -and $null -eq $child; $i++) {
        Start-Sleep -Milliseconds 100
        $child = Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $Parent.Id + " AND Name = 'PING.EXE'")
    }
    if ($null -eq $child) { return $null }
    $childProc = [System.Diagnostics.Process]::GetProcessById([int]$child.ProcessId)
    if ([PkHarnessProcSec]::DenyTerminate($childProc.Handle) -ne 0) { return $null }
    return $childProc
}

Reset-Harness
$tkStart = Start-PkProcess -FilePath $cmdExe -Arguments ('/c ""' + $pingExe + '" -n 7 127.0.0.1"')
$tkChild = Protect-HarnessPingChild -Parent $tkStart.Proc
$tkKilled = Stop-PkProcessTree -Process $tkStart.Proc
$tkNote = if ($null -ne $tkChild -and -not $tkChild.HasExited) { "the protected child survived" } else { "taskkill killed the child anyway, so this run doesn't exercise the failure path" }
Test-Assert ($null -ne $tkChild -and $tkKilled -and $tkStart.Proc.HasExited) ("Stop-PkProcessTree returns `$true for a program it killed when part of its tree couldn't be (returned " + $tkKilled + "; " + $tkNote + ")")
$tkStart.Proc.Dispose()
if ($null -ne $tkChild) { $tkChild.Dispose() }

# And a job killed for its time limit has TimedOut = $true.
$tkFeed = @{ Given = $false }
$tkLog = [System.Collections.Generic.List[object]]::new()
$null = Invoke-PkProcessDispatch -MaxConcurrent 1 -TimeoutSeconds 1 `
    -GroupProvider { if ($tkFeed.Given) { return $null }; $tkFeed.Given = $true; return 'g' }.GetNewClosure() `
    -JobBuilder { param($g) return @(@{ FilePath = $cmdExe; Arguments = ('/c ""' + $pingExe + '" -n 7 127.0.0.1"') }) }.GetNewClosure() `
    -JobStarter {
        param($job)
        $s = Start-PkProcess -FilePath $job['FilePath'] -Arguments $job['Arguments']
        $job['Proc'] = $s.Proc; $job['StdoutTask'] = $s.StdoutTask; $job['StderrTask'] = $s.StderrTask; $job['Stopwatch'] = $s.Stopwatch
        $job['Child'] = Protect-HarnessPingChild -Parent $s.Proc
        return $job
    } `
    -JobFinalize { param($job, $q) $tkLog.Add(@{ TimedOut = $job['TimedOut']; Protected = ($null -ne $job['Child']) }); if ($null -ne $job['Child']) { $job['Child'].Dispose() } }.GetNewClosure()
Test-Assert ($tkLog.Count -eq 1 -and $tkLog[0].Protected -and $tkLog[0].TimedOut -eq $true) ("a job killed for its time limit has TimedOut = `$true even when part of its tree survives (" + (@($tkLog | ForEach-Object { 'TimedOut=' + $_.TimedOut + ', child protected=' + $_.Protected }) -join '; ') + ")")
Reset-Harness
Write-Host ""

Write-Host "=== AK: 3.0 parameter changes ===" -ForegroundColor Cyan

# Complete-PkProcess -Dispose is a switch, and only -Job binds by position, so
# -Dispose $true is an error instead of a 1 ms -StreamTimeoutMs.
Reset-Harness
$apiStarted = Start-PkProcess -FilePath $cmdExe -Arguments '/c echo pk-api'
$null = $apiStarted.Proc.WaitForExit(10000)
$threw = $null
try { $null = Complete-PkProcess -Job $apiStarted -Dispose $true } catch { $threw = [string]$_ }
Test-Assert ($threw -like "*positional parameter*'True'*") ("Complete-PkProcess -Dispose `$true is an error (" + $threw + ")")
$threw = $null
try { $null = Complete-PkProcess $apiStarted 5000 } catch { $threw = [string]$_ }
Test-Assert ($threw -like "*positional parameter*'5000'*") ("a -StreamTimeoutMs by position is an error (" + $threw + ")")
$apiDone = Complete-PkProcess $apiStarted -Dispose
Test-Assert ($apiDone.ExitCode -eq 0 -and ([string]$apiDone.Stdout).Trim() -eq 'pk-api') "Complete-PkProcess `$job -Dispose works, -Job by position"

# Write-PkMessage -Level: Info, Warn, Error, or Warning as Warn; a handler
# only ever sees those three, spelled that way. Anything else is an error.
Reset-Harness
Write-PkMessage 'pk-level-1' -Level Warning
Write-PkMessage 'pk-level-2' -Level warn
Write-PkMessage 'pk-level-3' -Level ERROR
Write-PkMessage 'pk-level-4' -Level info
$apiLevels = (@($script:messages | Where-Object { $_.Message -like 'pk-level-*' } | ForEach-Object { $_.Level }) -join ',')
Test-Assert ($apiLevels -ceq 'Warn,Warn,Error,Info') ("Write-PkMessage passes Warning on as Warn, and normalizes the case (" + $apiLevels + ")")
$threw = $null
try { Write-PkMessage 'pk-level-bad' -Level Debug } catch { $threw = [string]$_ }
Test-Assert ($threw -like '*Level*Debug*' -and (Get-StartMessageCount '*pk-level-bad*') -eq 0) ("an unknown -Level is an error (" + $threw + ")")
Reset-Harness
$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams (New-JobList -Jobs @(@{ Id = 1 })) -WorkerScript { param($Id) Write-PkMessage 'pk-level-worker' -Level Warning }
$apiLevels = (@($script:messages | Where-Object { $_.Message -eq 'pk-level-worker' } | ForEach-Object { $_.Level }) -join ',')
Test-Assert ($apiLevels -ceq 'Warn') ("and the same from a worker (" + $apiLevels + ")")

# The dispatcher's -PollCallback, and its alias -AbortPollCallback.
Reset-Harness
foreach ($apiName in 'PollCallback', 'AbortPollCallback') {
    $apiFeed = @{ Given = $false; Polls = 0 }
    $apiParams = @{
        MaxConcurrent = 1
        GroupProvider = { if ($apiFeed.Given) { return $null }; $apiFeed.Given = $true; return 'g' }.GetNewClosure()
        JobBuilder    = { param($g) return @(@{ FilePath = $cmdExe; Arguments = '/c exit 0' }) }.GetNewClosure()
        JobFinalize   = { param($job, $q) $null = Complete-PkProcess -Job $job }
    }
    $apiParams[$apiName] = { param($running) $apiFeed.Polls++ }.GetNewClosure()
    $apiRun = Invoke-PkProcessDispatch @apiParams
    Test-Assert ($apiFeed.Polls -gt 0 -and $apiRun.GroupResults.Count -eq 1) ("the dispatcher takes -" + $apiName + " (" + $apiFeed.Polls + " passes)")
}
Test-Assert ((Get-Command Invoke-PkProcessDispatch).Parameters['PollCallback'].Aliases -contains 'AbortPollCallback') "-AbortPollCallback is an alias of -PollCallback"
Reset-Harness
Write-Host ""

# ==============================================================================
Write-Host "=== AL: a job is marked done before its shared slot is released ===" -ForegroundColor Cyan
# Released first, a stop landing before the mark has the teardown release the
# slot again, leaving a shared budget one above its limit. The window is one
# statement wide, too narrow to hit from a test, so this reads the dispatcher's
# code: the statement right before each `if ($pkIsSharedBudget) { ...Release() }`
# marks the job done (SlotReleased set, or $pkStarting cleared on a failed start).
$slotCoreAst = & (Get-Module ParallelKit) { (Get-Command Invoke-PkProcessDispatchCore).ScriptBlock.Ast }
$slotReleases = @($slotCoreAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $a.Member.Extent.Text -eq 'Release' -and $a.Expression.Extent.Text -eq '$pkMaxConcurrent' }, $true))
$slotMarkedFirst = 0
foreach ($slotCall in $slotReleases) {
    $slotIf = $slotCall.Parent
    while ($null -ne $slotIf -and -not ($slotIf -is [System.Management.Automation.Language.IfStatementAst] -and $slotIf.Clauses[0].Item1.Extent.Text -eq '$pkIsSharedBudget')) { $slotIf = $slotIf.Parent }
    if ($null -eq $slotIf -or $slotIf.Parent -isnot [System.Management.Automation.Language.StatementBlockAst]) { continue }
    $slotSiblings = $slotIf.Parent.Statements
    $slotIndex = $slotSiblings.IndexOf($slotIf)
    if ($slotIndex -lt 1) { continue }
    $slotBefore = $slotSiblings[$slotIndex - 1].Extent.Text
    if ($slotBefore -eq '$pkJob[''SlotReleased''] = $true' -or $slotBefore -eq '$pkStarting = $null') { $slotMarkedFirst++ }
}
Test-Assert ($slotReleases.Count -gt 0 -and $slotMarkedFirst -eq $slotReleases.Count) ("every shared-slot release comes after its job is marked done (" + $slotMarkedFirst + " of " + $slotReleases.Count + ")")
Write-Host ""

Write-Host "=== AM: a program is in the Job Object from its first instruction ===" -ForegroundColor Cyan
# Start-PkProcess has Windows create the program inside the kit's Job Object,
# so a child it starts at once (cmd /c tool.exe) is in the job too. The race
# this closes can't be forced, so these check the mechanism: .NET's start lock
# is found (without it the kit falls back to Process.Start), grandchildren are
# in the job, output isn't held open by a plain Process.Start elsewhere, and
# the fallback still works.
if (-not ([System.Management.Automation.PSTypeName]'PkHarnessJobProbe').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PkHarnessJobProbe {
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    // null when the process can't be opened (already gone).
    public static object InJob(int pid, IntPtr job) {
        IntPtr h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) { return null; }
        try { bool r; if (!IsProcessInJob(h, job, out r)) { return null; } return r; }
        finally { CloseHandle(h); }
    }
}
'@
}
$jobHandle = [PkChildProcessJob].GetField('_job', [System.Reflection.BindingFlags]'NonPublic,Static').GetValue($null)
$lockKind = [PkChildProcessJob]::StartLockKind
Test-Assert ($lockKind -match '^(Monitor|Lock):s_[Cc]reateProcessLock$') ("the kit holds .NET's process-start lock on this runtime (" + $lockKind + "); if not, a new .NET changed it and the kit is back to Process.Start")

$jobInside = 0; $jobFound = 0
for ($jobBatch = 0; $jobBatch -lt 2; $jobBatch++) {
    $jobStarted = @()
    for ($i = 0; $i -lt 20; $i++) { $jobStarted += Start-PkProcess -FilePath cmd.exe -Arguments '/d /c ping -n 3 127.0.0.1 >nul' }
    foreach ($s in $jobStarted) {
        $ping = $null
        for ($t = 0; $t -lt 40 -and -not $ping; $t++) {
            $ping = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $s['Proc'].Id + " AND Name='PING.EXE'")
            if (-not $ping) { Start-Sleep -Milliseconds 25 }
        }
        if ($ping) {
            $jobFound++
            if ([PkHarnessJobProbe]::InJob([int]@($ping)[0].ProcessId, $jobHandle) -eq $true) { $jobInside++ }
        }
    }
    foreach ($s in $jobStarted) { $null = Complete-PkProcess $s -Dispose }
}
Test-Assert ($jobFound -eq 40 -and $jobInside -eq 40) ("every cmd /c ping grandchild is in the Job Object (" + $jobInside + " of " + $jobFound + " found, 40 started)")

$jobBad = 0
for ($i = 0; $i -lt 20; $i++) { $r = Complete-PkProcess (Start-PkProcess -FilePath cmd.exe -Arguments "/d /c exit $i") -Dispose; if ($r.ExitCode -ne $i) { $jobBad++ } }
Test-Assert ($jobBad -eq 0) "a program that exits at once still reports its exit code (20 runs)"

$s = Start-PkProcess -FilePath ping.exe -Arguments '-n 30 127.0.0.1'
$jobRunning = $s['Proc'].HasExited -eq $false -and -not $s['Proc'].WaitForExit(200)
$s['Proc'].Kill(); $null = $s['Proc'].WaitForExit(5000)
Test-Assert ($jobRunning -and $s['Proc'].HasExited -and $s['StdoutTask'].Wait(5000)) "the Proc is a working Process: HasExited, WaitForExit and Kill, and the output ends after a kill"
$s['Proc'].Dispose()

$jobMsg = ''
try { $null = Start-PkProcess -FilePath 'C:\no\such\program.exe' } catch { $jobMsg = $_.ToString() }
Test-Assert ($jobMsg -like "*could not start*cannot find the file*" -and $jobMsg -notlike '*Exception calling*') ("a start error gives Windows' reason without PowerShell's method-call wrapper: " + $jobMsg)

# A plain Process.Start in another runspace, over and over, must not pick up
# the pipe ends of a program the kit is starting.
$jobFlag = [hashtable]::Synchronized(@{ Stop = $false })
$jobPs = [PowerShell]::Create()
$null = $jobPs.AddScript({
    param($flag)
    while (-not $flag.Stop) {
        $psi = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\PING.EXE'), '-n 4 127.0.0.1')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi); $p.Dispose()
        Start-Sleep -Milliseconds 20
    }
}).AddArgument($jobFlag)
$jobAsync = $jobPs.BeginInvoke()
Start-Sleep -Milliseconds 300
$jobLate = 0
for ($i = 0; $i -lt 40; $i++) {
    $s = Start-PkProcess -FilePath cmd.exe -Arguments '/d /c echo x'
    if (-not $s['StdoutTask'].Wait(1500)) { $jobLate++ }
    $null = Complete-PkProcess $s -Dispose
}
$jobFlag.Stop = $true
$null = $jobPs.EndInvoke($jobAsync); $jobPs.Dispose()
Test-Assert ($jobLate -eq 0) ("output isn't held open by a plain Process.Start running alongside (" + $jobLate + " of 40 late)")

[PkChildProcessJob]::TestUseProcessStart = $true
try {
    $s = Start-PkProcess -FilePath cmd.exe -Arguments '/d /c "echo fb& exit /b 5"'
    $jobFbInJob = [PkHarnessJobProbe]::InJob($s['Proc'].Id, $jobHandle)
    $r = Complete-PkProcess $s -Dispose
    Test-Assert ($r.ExitCode -eq 5 -and $r.Stdout.Trim() -eq 'fb' -and $jobFbInJob -ne $false) "without the start lock, Start-PkProcess falls back to Process.Start and still assigns the job"
} finally { [PkChildProcessJob]::TestUseProcessStart = $false }
Write-Host ""

Write-Host "=== AN: static checks on the kit's own code ===" -ForegroundColor Cyan
# Rules that are easy to break in one place without any other test noticing:
# the dispatcher's copied blocks drifting apart, a user callback called
# without the continue/break guard, an empty catch with no reason. Each check
# reads ParallelKit.ps1, then an edited copy that breaks the rule once, so a
# check that has stopped seeing anything fails too.
$anSource = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot "ParallelKit.ps1"))

function Get-HarnessCodeText {
    # Code as one line of tokens: comments, line breaks and spacing don't count.
    param([string]$Text)
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    $skip = @('Comment', 'NewLine', 'LineContinuation', 'EndOfInput')
    $kept = foreach ($token in $tokens) { if ($skip -notcontains $token.Kind.ToString()) { $token.Text } }
    return (@($kept) -join ' ')
}

function Get-HarnessCodeDifference {
    # Where two Get-HarnessCodeText strings first differ, for a failure message.
    param([string]$A, [string]$B)
    $i = 0
    while ($i -lt $A.Length -and $i -lt $B.Length -and $A[$i] -eq $B[$i]) { $i++ }
    $from = [Math]::Max(0, $i - 40)
    return ("'..." + $A.Substring($from, [Math]::Min(80, $A.Length - $from)) + "...' vs '..." + $B.Substring($from, [Math]::Min(80, $B.Length - $from)) + "...'")
}

function Get-HarnessDispatchCore {
    param([string]$Source)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    return $ast.Find({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-PkProcessDispatchCore' }, $true)
}

function Get-HarnessFinalizePassDrift {
    # The dispatcher's three poll/finalize passes (main loop, graceful wait,
    # final pass) are copies on purpose: a shared function cost too much per
    # job on 5.1. They must match apart from two intended differences: the
    # final pass has no time-limit check (what's left is force-stopped right
    # after), and each invariant message names its own pass. Returns what's
    # wrong; empty when they match.
    param([string]$Source)
    $problems = [System.Collections.Generic.List[string]]::new()
    $core = Get-HarnessDispatchCore -Source $Source
    if ($null -eq $core) { $problems.Add('Invoke-PkProcessDispatchCore not found'); return ,$problems }
    $passes = @($core.FindAll({ param($a) $a -is [System.Management.Automation.Language.ForEachStatementAst] -and $a.Condition.Extent.Text -eq '$pkRunning' -and $a.Body.Extent.Text.Contains('& $pkJobPollCompleted') }, $true))
    $names = @('main poll pass', 'graceful-wait loop', 'final pass')
    if ($passes.Count -ne 3) { $problems.Add('expected 3 passes, found ' + $passes.Count); return ,$problems }
    $timeLimit = Get-HarnessCodeText -Text 'if ($pkJob[''TimeLimit''] -gt 0) { Stop-PkTimedOutJob -Job $pkJob }'
    $messagePattern = '"ProcessDispatch: invariant violation - job''s GroupKey is not registered \(([^)]*)\)[^"]*"'
    $texts = @()
    for ($i = 0; $i -lt 3; $i++) {
        $text = Get-HarnessCodeText -Text $passes[$i].Extent.Text
        $named = [regex]::Match($text, $messagePattern)
        if (-not $named.Success -or $named.Groups[1].Value -ne $names[$i]) { $problems.Add('the ' + $names[$i] + "'s invariant message doesn't name it") }
        $text = [regex]::Replace($text, $messagePattern, '"<invariant message>"')
        $text = $text.Replace('$pkStillRunning', '$pkStillWaiting')
        $hasTimeLimit = $text.Contains($timeLimit)
        if ($i -lt 2 -and -not $hasTimeLimit) { $problems.Add('the ' + $names[$i] + ' has no time-limit check') }
        if ($i -eq 2 -and $hasTimeLimit) { $problems.Add('the final pass has a time-limit check') }
        $texts += $text.Replace($timeLimit + ' ', '')
    }
    for ($i = 1; $i -lt 3; $i++) {
        if ($texts[$i] -ne $texts[0]) { $problems.Add('the ' + $names[$i] + ' differs from the main poll pass: ' + (Get-HarnessCodeDifference -A $texts[0] -B $texts[$i])) }
    }
    return ,$problems
}

function Get-HarnessForceStopDrift {
    # The force-stop after an abort's wait and the finally block's teardown
    # run the same per-job steps, apart from one intended difference: the
    # teardown skips -JobAbortCleanup for a job whose -JobFinalize was running.
    param([string]$Source)
    $problems = [System.Collections.Generic.List[string]]::new()
    $core = Get-HarnessDispatchCore -Source $Source
    if ($null -eq $core) { $problems.Add('Invoke-PkProcessDispatchCore not found'); return ,$problems }
    $skipCondition = '-not [object]::ReferenceEquals($pkJob, $pkFinalizing)'
    $texts = @{}
    foreach ($list in '$pkRunning', '$pkTearDown') {
        $loops = @($core.FindAll({ param($a) $a -is [System.Management.Automation.Language.ForEachStatementAst] -and $a.Condition.Extent.Text -eq $list -and $a.Body.Extent.Text.Contains('$pkJobAbortCleanup') }.GetNewClosure(), $true))
        if ($loops.Count -ne 1) { $problems.Add('expected one stop loop over ' + $list + ', found ' + $loops.Count); continue }
        $loop = $loops[0]
        $steps = [System.Collections.Generic.List[string]]::new()
        $siblings = $loop.Parent.Statements
        $at = $siblings.IndexOf($loop)
        if ($at -lt 1) { $problems.Add('nothing runs before the stop loop over ' + $list + ' (expected Stop-PkJobProcesses)'); continue }
        $before = $siblings[$at - 1]
        $steps.Add((Get-HarnessCodeText -Text $before.Extent.Text).Replace($list, '$LIST'))
        $skipped = $false
        foreach ($statement in $loop.Body.Statements) {
            if ($statement -is [System.Management.Automation.Language.IfStatementAst] -and $statement.Clauses[0].Item1.Extent.Text -eq $skipCondition) {
                $skipped = $true
                foreach ($inner in $statement.Clauses[0].Item2.Statements) { $steps.Add((Get-HarnessCodeText -Text $inner.Extent.Text)) }
            } else {
                $steps.Add((Get-HarnessCodeText -Text $statement.Extent.Text))
            }
        }
        if ($list -eq '$pkTearDown' -and -not $skipped) { $problems.Add("the teardown doesn't skip the job mid-finalize") }
        if ($list -eq '$pkRunning' -and $skipped) { $problems.Add('the force-stop skips the job mid-finalize') }
        $texts[$list] = ($steps -join ' ; ')
    }
    if ($texts.Count -eq 2 -and $texts['$pkRunning'] -ne $texts['$pkTearDown']) {
        $problems.Add('the teardown differs from the force-stop: ' + (Get-HarnessCodeDifference -A $texts['$pkRunning'] -B $texts['$pkTearDown']))
    }
    return ,$problems
}

function Get-HarnessUnguardedCallbacks {
    # Every call of a user callback (`& $cb`, `. $cb`, `& $h['cb']`) must be
    # Invoke-PkCallback's guard or its inlined copy: `$flag = $false`, then
    # `do { & $cb ...; $flag = $true } while ($false)`, then
    # `if (-not $flag) { <loop warning> }`. `$cb.Invoke()` skips the guard
    # altogether, so it's refused. The variables below hold the kit's own
    # helpers, not callbacks; a new helper captured into a variable goes on
    # this list. Invoke-PkRun's `& $ScriptBlock` is the run itself, not called
    # from a loop. Returns @{ Calls; Problems }.
    param([string]$Source)
    $internal = @('$pkNewBatchResult', '$pkGetStartFailureCause', '$pkGetJobTimeLimit', '$pkReportStartFailure', '$pkStartProcessCore', '$pkWriteCallbackLoopWarning')
    $problems = [System.Collections.Generic.List[string]]::new()
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
    $calls = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and ($a.InvocationOperator -eq 'Ampersand' -or $a.InvocationOperator -eq 'Dot') -and $a.CommandElements[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and $a.CommandElements[0] -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true))
    $invokes = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ($a.Member.Extent.Text -eq 'Invoke' -or $a.Member.Extent.Text -eq 'InvokeReturnAsIs') }, $true))
    foreach ($call in $invokes) { $problems.Add('line ' + $call.Extent.StartLineNumber + ' (' + $call.Extent.Text + '): call a callback with & inside the guard, not .Invoke()') }
    $checked = 0
    foreach ($call in $calls) {
        $name = $call.CommandElements[0].Extent.Text
        if ($internal -contains $name) { continue }
        if ($name -eq '$ScriptBlock') {
            $function = $call.Parent
            while ($null -ne $function -and $function -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $function = $function.Parent }
            if ($null -ne $function -and $function.Name -eq 'Invoke-PkRun') { continue }
        }
        $checked++
        $where = 'line ' + $call.Extent.StartLineNumber + ' (' + $call.Extent.Text.Substring(0, 1) + ' ' + $name + ')'
        $loop = $call.Parent.Parent
        if ($loop -is [System.Management.Automation.Language.AssignmentStatementAst] -and $loop.Left.Extent.Text -eq '$null') { $loop = $loop.Parent }
        $loop = $loop.Parent
        if ($loop -isnot [System.Management.Automation.Language.DoWhileStatementAst] -or $loop.Condition.Extent.Text -ne '$false') { $problems.Add($where + ': not inside do { } while ($false)'); continue }
        $last = $loop.Body.Statements[$loop.Body.Statements.Count - 1]
        if ($last -isnot [System.Management.Automation.Language.AssignmentStatementAst] -or $last.Right.Extent.Text -ne '$true') { $problems.Add($where + ": the do block doesn't end by setting a flag to `$true"); continue }
        $flag = $last.Left.Extent.Text
        $flagPattern = [regex]::Escape($flag) + '(?![\w:])'
        $statement = $loop
        if ($loop.Parent -is [System.Management.Automation.Language.AssignmentStatementAst]) { $statement = $loop.Parent }
        $siblings = $statement.Parent.Statements
        $index = $siblings.IndexOf($statement)
        # The last statement before the call that mentions the flag resets it.
        $reset = $null
        for ($j = $index - 1; $j -ge 0 -and $null -eq $reset; $j--) {
            if ($siblings[$j].Extent.Text -match $flagPattern) { $reset = Get-HarnessCodeText -Text $siblings[$j].Extent.Text }
        }
        if ($reset -ne ($flag + ' = $false')) { $problems.Add($where + ': ' + $flag + ' is not reset to $false before the call'); continue }
        # ...and the first one after it that mentions the flag is the warning.
        $next = $null
        for ($j = $index + 1; $j -lt $siblings.Count -and $null -eq $next; $j++) {
            if ($siblings[$j].Extent.Text -match $flagPattern) { $next = $siblings[$j] }
        }
        if ($next -isnot [System.Management.Automation.Language.IfStatementAst] -or -not $next.Clauses[0].Item1.Extent.Text.StartsWith('-not ' + $flag) -or $next.Clauses[0].Item2.Extent.Text -notmatch "Write-PkCallbackLoopWarning|\`$pkWriteCallbackLoopWarning|used 'continue' or 'break'") {
            $problems.Add($where + ': not followed by the loop warning when ' + $flag + ' is still $false')
        }
    }
    return @{ Calls = $checked; Problems = $problems }
}

function Get-HarnessSilentCatches {
    # An empty catch (PowerShell, or C# in an Add-Type block) needs its reason:
    # a comment after it on the same line, or a comment line right above it.
    # Here-strings count too: their code runs as well. Returns @{ Catches; Problems }.
    param([string]$Source)
    $lines = $Source -split "`r?`n"
    $problems = [System.Collections.Generic.List[string]]::new()
    $found = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $after = $null
        if ($lines[$i] -match 'catch\s*(\[[^\]]*\]\s*|\([^)]*\)\s*)*\{\s*\}(.*)$') { $after = $Matches[2] }
        elseif ($lines[$i] -match 'catch\s*(\[[^\]]*\]\s*|\([^)]*\)\s*)*\{\s*$') {
            # A body on the lines below: empty if only blank lines come before its `}`.
            $k = $i + 1
            while ($k -lt $lines.Count -and $lines[$k].Trim() -eq '') { $k++ }
            if ($k -lt $lines.Count -and $lines[$k] -match '^\s*\}(.*)$') { $after = $Matches[1] }
        }
        if ($null -eq $after) { continue }
        $found++
        if ($after -match '#|//') { continue }
        if ($i -gt 0 -and $lines[$i - 1] -match '^\s*(#|//)') { continue }
        $problems.Add('line ' + ($i + 1) + ': ' + $lines[$i].Trim())
    }
    return @{ Catches = $found; Problems = $problems }
}

$anPasses = Get-HarnessFinalizePassDrift -Source $anSource
Test-Assert ($anPasses.Count -eq 0) ("the dispatcher's three finalize passes match, apart from the time limit and each message's pass name" + $(if ($anPasses.Count) { ': ' + ($anPasses -join '; ') }))
$anStops = Get-HarnessForceStopDrift -Source $anSource
Test-Assert ($anStops.Count -eq 0) ("the dispatcher's force-stop and its teardown run the same steps, apart from the mid-finalize skip" + $(if ($anStops.Count) { ': ' + ($anStops -join '; ') }))
$anGuards = Get-HarnessUnguardedCallbacks -Source $anSource
Test-Assert ($anGuards.Calls -gt 0 -and $anGuards.Problems.Count -eq 0) ("every user-callback call is guarded against continue/break (" + $anGuards.Calls + " calls)" + $(if ($anGuards.Problems.Count) { ': ' + ($anGuards.Problems -join '; ') }))
$anCatches = Get-HarnessSilentCatches -Source $anSource
Test-Assert ($anCatches.Catches -gt 0 -and $anCatches.Problems.Count -eq 0) ("every empty catch says why (" + $anCatches.Catches + " catches)" + $(if ($anCatches.Problems.Count) { ': ' + ($anCatches.Problems -join '; ') }))

# Each check on a copy broken in exactly one spot.
$anFinalMessage = 'is not registered (final pass). This should be unreachable.") -Level Error'
$anBroken = $anSource.Replace($anFinalMessage, $anFinalMessage + '; $pkOneSided = 1')
$anFound = Get-HarnessFinalizePassDrift -Source $anBroken
Test-Assert ($anBroken -ne $anSource -and $anFound.Count -eq 1 -and $anFound[0] -match '^the final pass differs') ("an edit to one finalize pass only is caught (" + ($anFound -join '; ') + ")")
$anBroken = $anSource.Replace('$pkJob[''SlotReleased''] = $true   # first, as in the force-stop above', '$pkJob[''SlotReleased''] = $false   # first, as in the force-stop above')
$anFound = Get-HarnessForceStopDrift -Source $anBroken
Test-Assert ($anBroken -ne $anSource -and $anFound.Count -eq 1 -and $anFound[0] -match '^the teardown differs') ("an edit to the teardown only is caught (" + ($anFound -join '; ') + ")")
$anBroken = $anSource.Replace('$null = do { & $pkOnComplete $pkJob[''Command''] $pkR; $pkCbDone = $true } while ($false)', '$null = & $pkOnComplete $pkJob[''Command''] $pkR; $pkCbDone = $true')
$anFound = (Get-HarnessUnguardedCallbacks -Source $anBroken).Problems
Test-Assert ($anBroken -ne $anSource -and $anFound.Count -eq 1 -and $anFound[0] -match '& \$pkOnComplete\): not inside do') ("a callback called without the guard is caught (" + ($anFound -join '; ') + ")")
$anFound = (Get-HarnessUnguardedCallbacks -Source ($anSource + "`r`nfunction Get-PkBroken { param(`$h, `$ScriptBlock) & `$h['Cb']; . `$h.Cb; & `$ScriptBlock; `$h['Cb'].Invoke() }`r`n")).Problems
Test-Assert ($anFound.Count -eq 4) ("callbacks called through an index, a property, a dot-source, or .Invoke() are caught too (" + ($anFound -join '; ') + ")")
$anFound = (Get-HarnessSilentCatches -Source ($anSource + "`r`nfunction Get-PkBroken { try { 1 } catch { } }`r`nfunction Get-PkBroken2 {`r`n    try { 1 } catch {`r`n`r`n    }`r`n}`r`n")).Problems
Test-Assert ($anFound.Count -eq 2 -and $anFound[0] -match 'Get-PkBroken' -and $anFound[1] -match 'try \{ 1 \} catch \{$') ("an empty catch with no reason is caught, on one line or several (" + ($anFound -join '; ') + ")")
Write-Host ""

Write-Host "=== AO: output held open by a leftover child sets StreamTimedOut ===" -ForegroundColor Cyan
# cmd exits at once, but the ping it starts with `start /b` keeps the output
# pipe open about 3 s longer.
Reset-Harness
$heldArgs = '/d /c echo before& start /b ping -n 4 127.0.0.1 >nul& echo after'
$s = Start-PkProcess -FilePath $cmdExe -Arguments $heldArgs
$null = $s['Proc'].WaitForExit(10000)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Complete-PkProcess $s -StreamTimeoutMs 1000 -Dispose
$sw.Stop()
Test-Assert ($r.StreamTimedOut -and $r.ExitCode -eq 0 -and $null -eq $r.StreamError -and $sw.Elapsed.TotalSeconds -ge 0.9 -and $sw.Elapsed.TotalSeconds -lt 3) ("Complete-PkProcess sets StreamTimedOut when a leftover child holds the output past -StreamTimeoutMs (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s, StreamTimedOut=" + $r.StreamTimedOut + ", ExitCode=" + $r.ExitCode + ")")
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-PkProcessWithTimeout -FilePath $cmdExe -Arguments $heldArgs -StreamTimeoutMs 1000
$sw.Stop()
Test-Assert ($r.StreamTimedOut -and $r.ExitCode -eq 0 -and $null -eq $r.StreamError -and $sw.Elapsed.TotalSeconds -lt 3) ("so does Invoke-PkProcessWithTimeout -StreamTimeoutMs (" + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s, StreamTimedOut=" + $r.StreamTimedOut + ")")
Write-Host ""

Write-Host "=== AP: repeated runs don't leak handles, threads or runspaces ===" -ForegroundColor Cyan
# Counted after a warm-up: the first runs grow the thread pool and JIT
# caches (on 5.1, handles climb about 100 over the first 20 runspace runs,
# then hold). After that the handle count still jumps by a few hundred and
# back between runs, on both runtimes and with a bare RunspacePool too, so
# one reading before and one after isn't enough: this compares the lowest
# reading over the last 20 warm-up runs with the lowest over the last 20
# measured ones. A leak raises that floor; the jumps don't. A leak of one
# handle, thread or runspace per run shows well past these margins. For the
# runspace engine the handle count isn't checked: it can sit 250-450 higher
# for 10-50 runs at a time, the same with a bare RunspacePool, which hides
# any leak worth looking for. Its thread and runspace counts are exact, and
# catch a pool or runspace left open.
function Get-HarnessResourceCount {
    [System.GC]::Collect(); [System.GC]::WaitForPendingFinalizers(); [System.GC]::Collect()
    $me = [System.Diagnostics.Process]::GetCurrentProcess()
    $count = @{ Handles = $me.HandleCount; Threads = $me.Threads.Count; Runspaces = @(Get-Runspace).Count }
    $me.Dispose()
    return $count
}
function Measure-HarnessGrowth {
    param([scriptblock]$Run, [int]$Warmup, [int]$Measured)
    $floors = @{}
    foreach ($phase in 'warm-up', 'measured') {
        $runs = $Warmup
        if ($phase -eq 'measured') { $runs = $Measured }
        $floor = $null
        for ($i = 0; $i -lt $runs; $i++) {
            & $Run
            if ($i -ge $runs - 20) {
                $c = Get-HarnessResourceCount
                if ($null -eq $floor) { $floor = $c }
                else { foreach ($k in @($c.Keys)) { if ($c[$k] -lt $floor[$k]) { $floor[$k] = $c[$k] } } }
            }
        }
        $floors[$phase] = $floor
    }
    $before = $floors['warm-up']; $after = $floors['measured']
    return @{ Handles = $after.Handles - $before.Handles; Threads = $after.Threads - $before.Threads; Runspaces = $after.Runspaces - $before.Runspaces }
}
$growthCases = [ordered]@{
    'Start-PkProcess'                          = @{ Measured = 100; Run = { $s = Start-PkProcess -FilePath $cmdExe -Arguments '/d /c exit 0'; $null = Complete-PkProcess $s -Dispose } }
    'Start-PkProcess, Process.Start fallback'  = @{ Measured = 100; Fallback = $true; Run = { $s = Start-PkProcess -FilePath $cmdExe -Arguments '/d /c exit 0'; $null = Complete-PkProcess $s -Dispose } }
    'Invoke-PkProcessBatch'                    = @{ Measured = 60; Run = { $null = Invoke-PkProcessBatch -MaxConcurrent 2 -Commands @(@{ FilePath = $cmdExe; Arguments = '/d /c exit 0' }, @{ FilePath = $cmdExe; Arguments = '/d /c exit 0' }) } }
    'Invoke-PkRunspaceJobs'                    = @{ Measured = 80; SkipHandles = $true; Run = { $null = Invoke-PkRunspaceJobs -WorkerScript { param([int]$Id) $Id } -JobParams @(@{ Id = 1 }, @{ Id = 2 }) -MaxParallel 2 } }
}
foreach ($growthName in $growthCases.Keys) {
    $growthCase = $growthCases[$growthName]
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($growthCase.ContainsKey('Fallback')) { [PkChildProcessJob]::TestUseProcessStart = $true }
    try { $growth = Measure-HarnessGrowth -Run $growthCase.Run -Warmup 40 -Measured $growthCase.Measured }
    finally { [PkChildProcessJob]::TestUseProcessStart = $false }
    $sw.Stop()
    $growthDetail = " (" + $growth.Handles + " handles, " + $growth.Threads + " threads, " + $growth.Runspaces + " runspaces; " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s)"
    if ($growthCase.ContainsKey('SkipHandles')) {
        Test-Assert ($growth.Threads -lt 10 -and $growth.Runspaces -le 0) ($growthName + ": " + $growthCase.Measured + " more runs after a warm-up leave threads and runspaces where they were" + $growthDetail)
    } else {
        Test-Assert ($growth.Handles -lt 50 -and $growth.Threads -lt 10 -and $growth.Runspaces -le 0) ($growthName + ": " + $growthCase.Measured + " more runs after a warm-up leave handles, threads and runspaces where they were" + $growthDetail)
    }
}
Write-Host ""

Write-Host "=== AQ: killing PowerShell outright leaves no programs running ===" -ForegroundColor Cyan
# The README's "no orphans": PowerShell killed with Stop-Process -Force runs
# no cleanup at all, so only the kit's Job Object can end its programs. A
# child PowerShell starts 3 `cmd /c ping` jobs and is killed; none of the
# pings may survive. Both start paths: created inside the job, and
# Process.Start then added to it.
$killScript = Join-Path $env:TEMP ("pk-hardkill-" + [guid]::NewGuid().ToString("N") + ".ps1")
[System.IO.File]::WriteAllText($killScript, @'
param([string]$Kit, [int]$Fallback)
. $Kit
if ($Fallback) { [PkChildProcessJob]::TestUseProcessStart = $true }
for ($i = 0; $i -lt 3; $i++) {
    $j = Start-PkProcess -FilePath cmd.exe -Arguments '/d /c ping -n 61 127.0.0.1 >nul'
    [Console]::Out.WriteLine($j['Proc'].Id)
}
[Console]::Out.WriteLine('READY'); [Console]::Out.Flush()
Start-Sleep -Seconds 60
'@)
try {
    foreach ($killFallback in 0, 1) {
        $killArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $killScript + '" -Kit "' + (Join-Path $PSScriptRoot 'ParallelKit.ps1') + '" -Fallback ' + $killFallback
        $psi = [System.Diagnostics.ProcessStartInfo]::new($selfExe, $killArgs)
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
        $killHost = [System.Diagnostics.Process]::Start($psi)
        $killCmds = @()
        while ($true) {
            $lineTask = $killHost.StandardOutput.ReadLineAsync()
            if (-not $lineTask.Wait(60000)) { break }
            if ($null -eq $lineTask.Result -or $lineTask.Result -eq 'READY') { break }
            $killCmds += [int]$lineTask.Result
        }
        # Each cmd.exe's ping.exe, once it's running.
        $killPings = @()
        foreach ($c in $killCmds) {
            $p = $null
            for ($t = 0; $t -lt 80 -and -not $p; $t++) {
                $p = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $c + " AND Name='PING.EXE'")
                if (-not $p) { Start-Sleep -Milliseconds 25 }
            }
            if ($p) { $killPings += [int]@($p)[0].ProcessId }
        }
        Stop-Process -Id $killHost.Id -Force
        $null = $killHost.WaitForExit(10000); $killHost.Dispose()
        $killLeft = @($killPings + $killCmds)
        for ($t = 0; $t -lt 30 -and $killLeft.Count -gt 0; $t++) {
            Start-Sleep -Milliseconds 100
            $killLeft = @($killLeft | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        }
        foreach ($id in $killLeft) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        $killPath = 'created inside the job'
        if ($killFallback) { $killPath = 'Process.Start fallback' }
        Test-Assert ($killPings.Count -eq 3 -and $killLeft.Count -eq 0) ("PowerShell killed outright takes its programs and their children with it, " + $killPath + " (" + $killPings.Count + " of 3 pings seen, " + $killLeft.Count + " still running)")
    }
} finally {
    try { [System.IO.File]::Delete($killScript) } catch { }   # temp file only; best effort
}
Write-Host ""

Write-Host "=== AR: both start paths give the same results ===" -ForegroundColor Cyan
# Creating a program inside the Job Object re-does what Process.Start does
# (command line, environment, working folder, output encoding, exit code),
# and Process.Start is the fallback when that can't be used. One table, run
# both ways, must come back the same.
$parityExe = Join-Path $env:TEMP ("pk-parity-" + [guid]::NewGuid().ToString("N") + ".exe")
$paritySrc = [System.IO.Path]::ChangeExtension($parityExe, '.cs')
[System.IO.File]::WriteAllText($paritySrc, @'
public static class PkParity {
    public static int Main(string[] args) {
        string t = "cwd=" + System.IO.Directory.GetCurrentDirectory() + "\n" + "env=" + System.Environment.GetEnvironmentVariable("PK_HARNESS_PARITY") + "\n";
        foreach (string a in args) { t += "[" + a + "]\n"; }
        t += new string(new char[] { (char)0x63, (char)0x61, (char)0x66, (char)0xE9, (char)0x20, (char)0x65E5, (char)0x672C });
        byte[] b = new System.Text.UTF8Encoding(false).GetBytes(t);
        System.IO.Stream o = System.Console.OpenStandardOutput();
        o.Write(b, 0, b.Length); o.Flush();
        System.Console.Error.Write("args=" + args.Length);
        return args.Length > 0 ? int.Parse(args[0]) : 0;
    }
}
'@)
$csc = $null
try { $csc = Invoke-PkProcessWithTimeout -FilePath $cscExe -Arguments (ConvertTo-PkArgumentString @('/nologo', ('/out:' + $parityExe), $paritySrc)) } catch { Write-Host "  csc.exe failed to run: $_" }
[System.IO.File]::Delete($paritySrc)
$compiled = ($null -ne $csc -and $csc.ExitCode -eq 0 -and [System.IO.File]::Exists($parityExe))
Test-Assert $compiled "the start-path test program compiles"
if ($compiled) {
    $parityUtf8 = 'caf' + [char]0xE9 + ' ' + [char]0x65E5 + [char]0x672C
    $parityCommands = @(
        @{ Name = 'access violation'; FilePath = $parityExe; Arguments = @('-1073741819', 'two words', 'say "hi"', 'C:\dir with space\', ''); OutputEncoding = 'utf-8' }
        @{ Name = 'largest exit code'; FilePath = $parityExe; Arguments = @('2147483647'); OutputEncoding = 'utf-8' }
        @{ Name = 'working folder'; FilePath = $parityExe; WorkingDirectory = $PSScriptRoot; OutputEncoding = 'utf-8' }
        @{ Name = 'cmd'; FilePath = $cmdExe; Arguments = '/d /c echo out& echo err 1>&2& exit /b 3' }
    )
    $parityRuns = @{}
    $env:PK_HARNESS_PARITY = 'set by the script'
    try {
        foreach ($parityPath in 'job', 'fallback') {
            [PkChildProcessJob]::TestUseProcessStart = ($parityPath -eq 'fallback')
            try { $b = Invoke-PkProcessBatch -Commands $parityCommands -MaxConcurrent 2 }
            finally { [PkChildProcessJob]::TestUseProcessStart = $false }
            $rows = @{}
            foreach ($br in $b.Results) { $rows[$br.Command['Name']] = $br }
            $parityRuns[$parityPath] = $rows
        }
    } finally { Remove-Item Env:PK_HARNESS_PARITY }
    $parityDiffs = @()
    foreach ($c in $parityCommands) {
        $a = $parityRuns['job'][$c['Name']]; $f = $parityRuns['fallback'][$c['Name']]
        if ($a.ExitCode -ne $f.ExitCode -or $a.Stdout -cne $f.Stdout -or $a.Stderr -cne $f.Stderr -or [string]$a.StartError -ne [string]$f.StartError) { $parityDiffs += $c['Name'] }
    }
    Test-Assert ($parityDiffs.Count -eq 0) ("exit code, stdout, stderr and start error are the same on both start paths" + $(if ($parityDiffs.Count) { " (differ: " + ($parityDiffs -join ', ') + ")" }))
    $job = $parityRuns['job']
    $av = $job['access violation']
    $expectedArgs = "[-1073741819]`n[two words]`n[say `"hi`"]`n[C:\dir with space\]`n[]`n"
    Test-Assert ($av.ExitCode -eq -1073741819 -and $av.Stdout.Contains("`nenv=set by the script`n" + $expectedArgs) -and $av.Stdout.EndsWith($parityUtf8) -and $av.Stderr -eq 'args=5') ("and they're right: the script's environment variable, a quoted argument list, UTF-8 output, stderr and a negative exit code (" + $av.ExitCode + ")")
    Test-Assert ($job['largest exit code'].ExitCode -eq 2147483647 -and $job['working folder'].Stdout.StartsWith('cwd=' + $PSScriptRoot + "`n") -and $job['cmd'].ExitCode -eq 3 -and $job['cmd'].Stdout.Trim() -eq 'out' -and $job['cmd'].Stderr.Trim() -eq 'err') ("the largest exit code, the working folder, and a cmd.exe command's output and exit code (" + $job['largest exit code'].ExitCode + ", " + ([string]$job['working folder'].Stdout).Split("`n")[0] + ")")
    try { [System.IO.File]::Delete($parityExe) } catch { }   # temp file only; best effort
}
Write-Host ""

Write-Host "=== AS: a callback that throws while programs run ===" -ForegroundColor Cyan
# The exception comes out of the call, every program is killed, and a shared
# budget gets every slot back. Each case throws once a long ping is running;
# its count (-n 53) marks it for the check afterwards. Groups: 'long' first
# (the ping), then 'quick' ones (cmd /c exit 0), or empty ones for
# -GroupReleaseCheck, which is only asked about groups with no jobs.
function Get-HarnessMarkedPings {
    return ,@(Get-CimInstance Win32_Process -Filter "Name='PING.EXE'" | Where-Object { [string]$_.CommandLine -like '* -n 53 *' })
}
$throwBudget = [System.Threading.SemaphoreSlim]::new(2, 2)
foreach ($throwName in 'PollCallback', 'GroupCompleteCallback', 'JobBuilder', 'GroupProvider', 'GroupReleaseCheck') {
    Reset-Harness
    $st = @{ Calls = 0; Thrown = $false; Long = @{ FilePath = $pingExe; Arguments = '-n 53 127.0.0.1' } }
    $p = @{
        MaxConcurrent = $throwBudget
        MaxQueueAhead = 2
        GroupProvider = { if ($st.Calls -ge 6) { return $null }; $st.Calls++; if ($st.Calls -eq 1) { return 'long' }; return 'quick' }.GetNewClosure()
        JobBuilder    = { param($g) if ($g -eq 'long') { return $st.Long }; return @{ FilePath = $cmdExe; Arguments = '/d /c exit 0' } }.GetNewClosure()
        JobFinalize   = { param($job, $q) $null = Complete-PkProcess -Job $job }
    }
    switch ($throwName) {
        'PollCallback' {
            $p['PollCallback'] = { param($running) if ($null -ne $st.Long['Proc'] -and -not $st.Long['Proc'].HasExited) { $st.Thrown = $true; throw 'pk-test: PollCallback' } }.GetNewClosure()
        }
        'GroupCompleteCallback' {
            $p['GroupCompleteCallback'] = { param($g) if ($null -ne $st.Long['Proc'] -and -not $st.Long['Proc'].HasExited) { $st.Thrown = $true; throw 'pk-test: GroupCompleteCallback' } }.GetNewClosure()
        }
        'JobBuilder' {
            $p['JobBuilder'] = { param($g) if ($g -eq 'long') { return $st.Long }; if ($null -ne $st.Long['Proc'] -and -not $st.Long['Proc'].HasExited) { $st.Thrown = $true; throw 'pk-test: JobBuilder' }; return @{ FilePath = $cmdExe; Arguments = '/d /c exit 0' } }.GetNewClosure()
        }
        'GroupProvider' {
            $p['GroupProvider'] = { if ($st.Calls -ge 6) { return $null }; $st.Calls++; if ($st.Calls -eq 1) { return 'long' }; if ($null -ne $st.Long['Proc'] -and -not $st.Long['Proc'].HasExited) { $st.Thrown = $true; throw 'pk-test: GroupProvider' }; return 'quick' }.GetNewClosure()
        }
        'GroupReleaseCheck' {
            $p['JobBuilder'] = { param($g) if ($g -eq 'long') { return $st.Long }; return @() }.GetNewClosure()
            $p['GroupReleaseCheck'] = { param($g) if ($null -ne $st.Long['Proc'] -and -not $st.Long['Proc'].HasExited) { $st.Thrown = $true; throw 'pk-test: GroupReleaseCheck' }; return $false }.GetNewClosure()
        }
    }
    $throwError = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $null = Invoke-PkProcessDispatch @p } catch { $throwError = [string]$_ }
    $sw.Stop()
    $throwLeft = Get-HarnessMarkedPings
    for ($t = 0; $t -lt 20 -and $throwLeft.Count -gt 0; $t++) { Start-Sleep -Milliseconds 100; $throwLeft = Get-HarnessMarkedPings }
    foreach ($l in $throwLeft) { Stop-Process -Id $l.ProcessId -Force -ErrorAction SilentlyContinue }
    $throwSlots = $throwBudget.CurrentCount
    if ($throwSlots -lt 2) { $null = $throwBudget.Release(2 - $throwSlots) }   # so one failure doesn't fail the cases after it
    Test-Assert ($st.Thrown -and $throwError -like ('*pk-test: ' + $throwName + '*') -and $throwLeft.Count -eq 0 -and $throwSlots -eq 2 -and $sw.Elapsed.TotalSeconds -lt 15) ("dispatcher: -" + $throwName + " throwing while a program runs: the exception comes out, nothing is left running, the shared budget gets its slots back (threw while running: " + $st.Thrown + ", error: " + $throwError + ", left running: " + $throwLeft.Count + ", slots: " + $throwSlots + " of 2, " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s)")
}
$throwBudget.Dispose()

# The runspace engine: a throwing -ResultHandler, -PollCallback or
# -NextJobProvider stops the run, stops the running workers (their pipelines
# are stopped, then the pool closes) and lets the exception out. Each worker
# notes when it starts and sleeps in 25 ms steps, so a stop lands at once;
# each throwing callback first waits for two workers to be running.
$rsWorker = {
    param([int]$Id, [int]$Ms, $Seen)
    $Seen[$Id] = 'started'
    $w = [System.Diagnostics.Stopwatch]::StartNew()
    while ($w.ElapsedMilliseconds -lt $Ms) { [System.Threading.Thread]::Sleep(25) }
    $Seen[$Id] = 'done'
    return $Id
}
$rsWaitRunning = {
    param($Seen)
    $w = [System.Diagnostics.Stopwatch]::StartNew()
    while (@($Seen.Values | Where-Object { $_ -eq 'started' }).Count -lt 2 -and $w.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 10 }
    return @($Seen.Values | Where-Object { $_ -eq 'started' }).Count
}
$rsBaseline = @(Get-Runspace).Count
foreach ($rsName in 'ResultHandler', 'PollCallback', 'NextJobProvider') {
    Reset-Harness
    $seen = [System.Collections.Concurrent.ConcurrentDictionary[int, string]]::new()
    $st = @{ Calls = 0; Running = -1 }
    $p = @{ WorkerScript = $rsWorker; MaxParallel = 3 }
    switch ($rsName) {
        'ResultHandler' {
            # Job 1 returns at once, while jobs 2 and 3 run on.
            $p['JobParams'] = @(@{ Id = 1; Ms = 0; Seen = $seen }, @{ Id = 2; Ms = 10000; Seen = $seen }, @{ Id = 3; Ms = 10000; Seen = $seen })
            $p['ResultHandler'] = { param($r) $st.Running = & $rsWaitRunning $seen; throw 'pk-test: ResultHandler' }.GetNewClosure()
        }
        'PollCallback' {
            $p['JobParams'] = @(@{ Id = 2; Ms = 10000; Seen = $seen }, @{ Id = 3; Ms = 10000; Seen = $seen })
            $p['PollCallback'] = { $st.Running = & $rsWaitRunning $seen; throw 'pk-test: PollCallback' }.GetNewClosure()
        }
        'NextJobProvider' {
            $p['NextJobProvider'] = { $st.Calls++; if ($st.Calls -le 2) { return @{ Id = $st.Calls + 1; Ms = 10000; Seen = $seen } }; $st.Running = & $rsWaitRunning $seen; throw 'pk-test: NextJobProvider' }.GetNewClosure()
        }
    }
    $rsError = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $null = Invoke-PkRunspaceJobs @p } catch { $rsError = [string]$_ }
    $sw.Stop()
    # The pool closes in the background once the stopped workers have ended.
    for ($t = 0; $t -lt 60 -and @(Get-Runspace).Count -gt $rsBaseline; $t++) { Start-Sleep -Milliseconds 50 }
    $rsLeft = @(Get-Runspace).Count - $rsBaseline
    Test-Assert ($rsError -like ('*pk-test: ' + $rsName + '*') -and $st.Running -eq 2 -and $rsLeft -le 0 -and $sw.Elapsed.TotalSeconds -lt 8) ("runspace jobs: -" + $rsName + " throwing while 2 workers run stops the run: the exception comes out and the workers' runspaces close (error: " + $rsError + ", workers running at the throw: " + $st.Running + ", runspaces left: " + $rsLeft + ", " + [math]::Round($sw.Elapsed.TotalSeconds, 1) + "s)")
}
Write-Host ""

Set-PkMessageHandler -Handler $null
Reset-PkAbortState

Write-Host "==============================================="
$skipText = ""
if ($script:skipCount -gt 0) { $skipText = ", " + $script:skipCount + " skipped" }
if ($script:failCount -eq 0) {
    Write-Host ("ALL PASSED  (" + $script:passCount + " assertions" + $skipText + ")") -ForegroundColor Green
} else {
    Write-Host ($script:failCount.ToString() + " FAILED, " + $script:passCount + " passed" + $skipText) -ForegroundColor Red
}
Write-Host "==============================================="

if ($script:failCount -gt 0) { exit 1 } else { exit 0 }
