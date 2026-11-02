# One trial of the ThreadJob / PoshRSJob scriptblock question, run in a fresh
# powershell.exe or pwsh.exe by run.ps1. Starts -Workers jobs with the given
# -Tool. Each job gets a payload made in this (the main) runspace and uses it
# -Iterations times:
#   JobValue      a scriptblock made here, passed in and run with & $sb
#   Delegate      a [Func[object]] made here from a scriptblock that runs a
#                 nested scriptblock (Where-Object { }), called with .Invoke()
#   TextJobValue  control: the JobValue block's text, rebuilt in the job
#   TextDelegate  control: the Delegate block's text, rebuilt and cast in the job
#   ProbeJobValue / ProbeDelegate  one call, reporting which session state and
#                 thread the payload ran on
# -Via says how the payload crosses: Args (-ArgumentList) or Using ($using:).
# -Main says what the main thread does meanwhile: Busy (loops over its own
# functions, like a dispatch loop) or Wait (blocked in Wait-Job / Wait-RSJob).
# Exit 0 = every iteration gave the right answer and the main runspace is
# intact; 2 = wrong answers, job errors or main-runspace damage; anything else
# means the process died. Progress goes to -ProgressFile.
param(
    [Parameter(Mandatory)][ValidateSet('ThreadJob', 'RSJob')][string]$Tool,
    [Parameter(Mandatory)][ValidateSet('JobValue', 'Delegate', 'TextJobValue', 'TextDelegate', 'ProbeJobValue', 'ProbeDelegate')][string]$Case,
    [ValidateSet('Args', 'Using')][string]$Via = 'Args',
    [ValidateSet('Busy', 'Wait')][string]$Main = 'Busy',
    [int]$Workers = 8,
    [int]$Iterations = 2000,
    [int]$WaitTimeoutSec = 40,
    [Parameter(Mandatory)][string]$ModuleDir,
    [Parameter(Mandatory)][string]$ProgressFile
)
$ErrorActionPreference = 'Stop'

[AppDomain]::CurrentDomain.SetData('pkProgressFile', $ProgressFile)
function Write-TrialLine([string]$line) { [System.IO.File]::AppendAllText($ProgressFile, $line + "`r`n") }
function Test-MainAlive { return 42 }

$global:pkMainOnly = 'set only in the main runspace'
$mainThread = [System.Threading.Thread]::CurrentThread.ManagedThreadId

try {
    if ($Tool -eq 'ThreadJob') {
        Import-Module (Join-Path $ModuleDir 'Microsoft.PowerShell.ThreadJob\2.2.0\Microsoft.PowerShell.ThreadJob.psd1') -Force
    } else {
        Import-Module (Join-Path $ModuleDir 'PoshRSJob\1.7.4.4\PoshRSJob.psd1') -Force
    }

    # Literal blocks, so they're bound to this runspace's session state (a
    # [scriptblock]::Create block is unbound, which is the safe text path).
    $jobValueBlock = { $x = [Math]::Sqrt(16); $null = [string]::Concat("a", "b"); $x }
    $delegateBlock = { @(1, 2, 3) | Where-Object { $_ -gt 1 } | Measure-Object | ForEach-Object Count }
    $probeBlock    = { [pscustomobject]@{ SeesMainVar = (Test-Path variable:global:pkMainOnly); Thread = [System.Threading.Thread]::CurrentThread.ManagedThreadId } }

    $payload = switch ($Case) {
        'JobValue'      { $jobValueBlock }
        'Delegate'      { [Func[object]]$delegateBlock }
        'TextJobValue'  { $jobValueBlock.ToString() }
        'TextDelegate'  { $delegateBlock.ToString() }
        'ProbeJobValue' { $probeBlock }
        'ProbeDelegate' { [Func[object]]$probeBlock }
    }

    $body = @'
$ok = 0; $errCount = 0; $errs = [System.Collections.Generic.List[string]]::new()
$f = switch ($Case) {
    'TextJobValue' { [scriptblock]::Create($Payload) }
    'TextDelegate' { [Func[object]][scriptblock]::Create($Payload) }
    default        { $Payload }
}
$isDelegate = $Case -in 'Delegate', 'TextDelegate', 'ProbeDelegate'
$expected = if ($Case -like '*JobValue') { 4 } else { 2 }
if ($Case -like 'Probe*') {
    $r = if ($isDelegate) { $f.Invoke() } else { & $f }
    $r = @($r)[0]
    return [pscustomobject]@{ Ok = 1; ErrorCount = 0; Errors = ''; PayloadType = $Payload.GetType().FullName
        SeesMainVar = $r.SeesMainVar; PayloadThread = $r.Thread; JobThread = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        JobSeesMainVar = (Test-Path variable:global:pkMainOnly) }
}
for ($i = 0; $i -lt $Iterations; $i++) {
    try {
        $r = if ($isDelegate) { $f.Invoke() } else { & $f }
        if ("$r" -eq "$expected") { $ok++ } else { $errCount++; if ($errs.Count -lt 3) { $errs.Add("wrong result '$r'") } }
    } catch {
        $errCount++; if ($errs.Count -lt 3) { $errs.Add($_.Exception.GetType().Name + ': ' + $_.Exception.Message) }
    }
}
[pscustomobject]@{ Ok = $ok; ErrorCount = $errCount; Errors = ($errs -join ' | '); PayloadType = $Payload.GetType().FullName }
'@
    if ($Via -eq 'Args') {
        $worker = [scriptblock]::Create("param(`$Payload, `$Case, `$Iterations)`n" + $body)
    } else {
        $worker = [scriptblock]::Create("`$Payload = `$using:payload; `$Case = `$using:Case; `$Iterations = `$using:Iterations`n" + $body)
    }

    $n = if ($Case -like 'Probe*') { 1 } else { $Workers }
    Write-TrialLine "start tool=$Tool case=$Case via=$Via main=$Main workers=$n ps=$($PSVersionTable.PSVersion) mainThread=$mainThread"
    $jobs = @(for ($w = 0; $w -lt $n; $w++) {
        if ($Tool -eq 'ThreadJob') {
            if ($Via -eq 'Args') { Start-ThreadJob -ScriptBlock $worker -ArgumentList $payload, $Case, $Iterations -ThrottleLimit $n }
            else { Start-ThreadJob -ScriptBlock $worker -ThrottleLimit $n }
        } else {
            if ($Via -eq 'Args') { Start-RSJob -ScriptBlock $worker -ArgumentList $payload, $Case, $Iterations -Throttle $n }
            else { Start-RSJob -ScriptBlock $worker -Throttle $n }
        }
    })
    Write-TrialLine "started $($jobs.Count) jobs"

    $damage = [System.Collections.Generic.List[string]]::new()
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    if ($Main -eq 'Wait') {
        if ($Tool -eq 'ThreadJob') { $null = Wait-Job -Job $jobs -Timeout $WaitTimeoutSec }
        else { $null = $jobs | Wait-RSJob -Timeout $WaitTimeoutSec }
    } else {
        $loops = 0
        while ($true) {
            $loops++
            if ((Test-MainAlive) -ne 42) { $damage.Add('Test-MainAlive returned the wrong value') }
            if (-not (Get-Command Test-MainAlive -ErrorAction SilentlyContinue)) { $damage.Add("Test-MainAlive vanished at loop $loops"); break }
            if ($global:pkMainOnly -ne 'set only in the main runspace') { $damage.Add("main variable changed at loop $loops"); break }
            $null = @(1..20 | Where-Object { $_ % 2 })
            $pending = @($jobs | Where-Object { $_.State -in 'NotStarted', 'Running' })
            if ($pending.Count -eq 0) { break }
            if ($clock.Elapsed.TotalSeconds -gt $WaitTimeoutSec) { break }
        }
    }
    $pending = @($jobs | Where-Object { $_.State -in 'NotStarted', 'Running' })
    if ($pending.Count -gt 0) {
        $timedOut = $true
        Write-TrialLine "timeout: $($pending.Count) jobs still running after $([int]$clock.Elapsed.TotalSeconds)s"
    }
    Write-TrialLine ("states: " + (($jobs | ForEach-Object { "$($_.State)" }) -join ','))

    if (-not $timedOut) {
        # PoshRSJob can flip State to Completed before the output is collected; Wait-RSJob settles it.
        if ($Tool -eq 'RSJob') { $null = $jobs | Wait-RSJob -Timeout 10 }
        $results =@(if ($Tool -eq 'ThreadJob') { Receive-Job -Job $jobs -ErrorAction Continue 2>&1 } else { $jobs | Receive-RSJob -ErrorAction Continue 2>&1 })
        $bad = 0; $okTotal = 0
        Write-TrialLine "received $($results.Count) outputs"
        foreach ($r in $results) {
            if ($r -is [System.Management.Automation.ErrorRecord]) { $bad++; Write-TrialLine "job error: $r"; continue }
            if ($null -eq $r -or -not $r.PSObject.Properties['Ok']) { $bad++; Write-TrialLine "odd output: $r"; continue }
            $okTotal += $r.Ok
            if ($r.ErrorCount -gt 0) { $bad++; Write-TrialLine "iteration errors=$($r.ErrorCount): $($r.Errors)" }
            if ($Case -like 'Probe*') {
                Write-TrialLine ("probe: payloadType={0} payloadSeesMainVar={1} jobSeesMainVar={2} payloadThread={3} jobThread={4} mainThread={5}" -f
                    $r.PayloadType, $r.SeesMainVar, $r.JobSeesMainVar, $r.PayloadThread, $r.JobThread, $mainThread)
            }
        }
        foreach ($j in $jobs) {
            if ($j.State -eq 'Failed') { $bad++; Write-TrialLine "job failed: $(if ($j.PSObject.Properties['Error']) { $j.Error } else { $j.JobStateInfo.Reason })" }
            if ($Tool -eq 'RSJob' -and $j.HasErrors) { $bad++; Write-TrialLine ("rsjob error: " + (($j.Error | ForEach-Object { "$_" }) -join ' | ')) }
        }
        $expectedOk = if ($Case -like 'Probe*') { 1 } else { $n * $Iterations }
        if ($okTotal -ne $expectedOk) { $bad++; Write-TrialLine "ok iterations $okTotal of $expectedOk" }
    } else { $bad = 1 }

    # The main runspace must still work after the jobs ran.
    if (-not (Get-Command Test-MainAlive -ErrorAction SilentlyContinue)) { $damage.Add('Test-MainAlive missing at end') }
    elseif ((Test-MainAlive) -ne 42) { $damage.Add('Test-MainAlive wrong at end') }
    foreach ($d in $damage) { Write-TrialLine "main damage: $d" }

    if (-not $timedOut) {
        if ($Tool -eq 'ThreadJob') { Remove-Job -Job $jobs -Force } else { $jobs | Remove-RSJob -Force }
    }
    if ($timedOut) { Write-TrialLine 'result: timeout'; [Environment]::Exit(4) }
    if ($bad -gt 0 -or $damage.Count -gt 0) { Write-TrialLine "result: wrong (bad=$bad damage=$($damage.Count))"; [Environment]::Exit(2) }
    Write-TrialLine 'result: ok'
    [Environment]::Exit(0)
} catch {
    $err = $_
    try { Write-TrialLine ("exception: " + $err.Exception.GetType().Name + ': ' + $err.Exception.Message + ' @ ' + $err.InvocationInfo.PositionMessage) }
    catch {
        # Write-TrialLine itself may be gone; log with .NET calls only, through a path kept outside session state.
        $why = 'logger failed: ' + $_.Exception.GetType().Name + ': ' + $_.Exception.Message + ' || original: ' + $err.Exception.GetType().Name + ': ' + $err.Exception.Message
        try { [System.IO.File]::AppendAllText([AppDomain]::CurrentDomain.GetData('pkProgressFile'), $why + "`r`n") } catch { }  # nothing left to log with
    }
    [Environment]::Exit(2)
}
