# One stress trial, run in a fresh powershell.exe by run.ps1.
# Runs -Rounds separate Invoke-PkRunspaceJobs calls (a new runspace pool, so
# fresh runspaces, each round). In each round all -Workers workers wait on a
# gate, then are released at the same instant into the -Mode body - the
# "first cmdlet call in two fresh runspaces at once" case this was written to
# test. Progress goes to -ProgressFile so the runner can tell which
# round a hung trial was in.
param(
    [Parameter(Mandatory)][string]$KitPath,
    [Parameter(Mandatory)][string]$Mode,
    [int]$Workers = 8,
    [int]$Rounds = 10,
    [Parameter(Mandatory)][string]$ProgressFile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $KitPath

function Write-Progress2([string]$line) { [System.IO.File]::AppendAllText($ProgressFile, $line + "`r`n") }

$tempDir = Join-Path $env:TEMP ('pk-cmdlet-hang-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDir

# Bodies run in the worker right after the gate opens. Each is the first use
# of its cmdlets in that runspace. Control uses no cmdlets at all.
$bodies = @{
    Control    = '$n = 0; for ($i = 0; $i -lt 1000; $i++) { $n += $i }; $null = [System.IO.Directory]::Exists($TempDir); $null = [DateTime]::Now'
    Core       = '$null = 1 | Out-Null; $null = @(1, 2, 3) | ForEach-Object { $_ * 2 } | Where-Object { $_ -gt 2 }; $null = Write-Output 1'
    Utility    = 'Start-Sleep -Milliseconds 1; $null = Get-Date; $null = 1..5 | Measure-Object -Sum; $null = 1..5 | Select-Object -First 2; $null = 1..5 | Sort-Object -Descending'
    Management = '$null = Test-Path -LiteralPath $TempDir; $null = Get-ChildItem -LiteralPath $env:SystemRoot -Filter *.exe; $null = Join-Path $TempDir x; $null = Get-Item -LiteralPath $TempDir'
    FileIO     = '$p = Join-Path $TempDir ("w" + $Index + ".log"); "line" | Out-File -FilePath $p -Append; Add-Content -Path $p -Value more; $null = Get-Content -Path $p'
}
$bodies['Mixed'] = $bodies['Utility'] + '; ' + $bodies['Management'] + '; ' + $bodies['FileIO'] + '; ' + $bodies['Core']

# Positive control: a known hang (README rule 2, a deadlock confirmed
# from a memory dump), to prove this rig can see one. Worker 0 builds a
# Lazy whose factory is a scriptblock delegate that itself hands another
# scriptblock delegate to AddOrUpdate, and publishes it. Then every worker
# forces .Value on 200 of them, in different orders, so a factory often runs
# on a thread that isn't its own runspace's while that runspace waits on the
# same Lazy.
# The Delegate* modes differ only in what the factory does (FACTORY_BODY):
#   DelegatePlain  - .NET calls only
#   DelegateCmdlet - cmdlets that take no scriptblock
#   DelegateWhere  - cmdlets that take a scriptblock (Where-Object/ForEach-Object)
#   DelegateNested - a nested scriptblock delegate (AddOrUpdate), no cmdlets
$factoryBodies = @{
    DelegatePlain  = '$n = 0; for ($j = 0; $j -lt 50; $j++) { $n += $j }; $null = [DateTime]::Now'
    DelegateCmdlet = '$null = Get-Date; $null = Test-Path -LiteralPath $TempDir; $null = 1 | Out-Null'
    DelegateWhere  = '$null = @(1, 2, 3) | Where-Object { $_ -gt 1 }; $null = @(1, 2) | ForEach-Object { $_ }'
    DelegateNested = '$null = $dict.AddOrUpdate(''k'', ''a'', [Func[string, string, string]] { param($k, $old) $old + ''b'' })'
}
$delegateBody = @'
$count = 200
if ($Index -eq 0) {
    $dict = [System.Collections.Concurrent.ConcurrentDictionary[string, string]]::new()
    $factory = [Func[object]] {
        FACTORY_BODY
        42
    }
    for ($i = 0; $i -lt $count; $i++) {
        $Shared[[string]$i] = [System.Lazy[object]]::new($factory, [System.Threading.LazyThreadSafetyMode]::ExecutionAndPublication)
    }
    $Gate2.Set()
} else {
    $Gate2.Wait()
}
for ($n = 0; $n -lt $count; $n++) {
    if ($Index % 2 -eq 0) { $i = $n } else { $i = $count - 1 - $n }
    $null = $Shared[[string]$i].Value
}
'@

# Job-parameter modes: a scriptblock made here on the main thread (so bound
# to the main runspace) is passed as a job value and run with & in every
# worker at once, while the main thread sits in the kit's poll loop.
#   JobParamPlain  - .NET calls only
#   JobParamCmdlet - cmdlets that take no scriptblock
#   JobParamWhere  - Where-Object/ForEach-Object with an inner scriptblock
#   JobParamText   - control: the JobParamWhere text, [scriptblock]::Create'd
#                    in the worker (the proposed workaround)
$jobFns = @{
    JobParamPlain  = { param($i) $n = 0; for ($j = 0; $j -lt 50; $j++) { $n += $j }; $n + $i }
    JobParamCmdlet = { param($i) $null = Get-Date; $null = Test-Path -LiteralPath $env:SystemRoot; $null = 1 | Out-Null; $i }
    JobParamWhere  = { param($i) @(1, 2, 3) | Where-Object { $_ -gt 1 } | ForEach-Object { $_ + $i } }
}
$jobFns['JobParamText'] = $jobFns['JobParamWhere'].ToString()
$jobParamBody = 'if ($Fn -is [string]) { $Fn = [scriptblock]::Create($Fn) }; for ($k = 0; $k -lt 500; $k++) { $null = & $Fn $k }'
$fn = $null

if ($factoryBodies.ContainsKey($Mode)) { $body = $delegateBody.Replace('FACTORY_BODY', $factoryBodies[$Mode]) }
elseif ($bodies.ContainsKey($Mode)) { $body = $bodies[$Mode] }
elseif ($jobFns.ContainsKey($Mode)) { $body = $jobParamBody; $fn = $jobFns[$Mode] }
else { throw "Unknown -Mode '$Mode'. Use one of: $(@($bodies.Keys + $factoryBodies.Keys + $jobFns.Keys) -join ', ')." }

$workerText = 'param($Ready, $Gate, $Gate2, $Shared, $Index, $TempDir, $Fn)' + "`r`n" +
    '$null = $Ready.Signal(); $Gate.Wait()' + "`r`n" + $body
$worker = [scriptblock]::Create($workerText)

$exitCode = 0
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        Write-Progress2 "round $round start"
        $ready  = [System.Threading.CountdownEvent]::new($Workers)
        $gate   = [System.Threading.ManualResetEventSlim]::new($false)
        $gate2  = [System.Threading.ManualResetEventSlim]::new($false)
        $shared = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        for ($i = 0; $i -lt $Workers; $i++) {
            $jobs.Add(@{ Ready = $ready; Gate = $gate; Gate2 = $gate2; Shared = $shared; Index = $i; TempDir = $tempDir; Fn = $fn })
        }
        $state = @{ Started = [System.Diagnostics.Stopwatch]::StartNew(); GateTimedOut = $false }
        # Open the gate once every worker is waiting at it. If one never gets
        # there in 15s, open it anyway and say so - that's a startup stall,
        # not the race this test is after.
        $poll = {
            if (-not $gate.IsSet) {
                if ($ready.CurrentCount -eq 0) { $gate.Set() }
                elseif ($state.Started.Elapsed.TotalSeconds -gt 15) { $state.GateTimedOut = $true; $gate.Set() }
            }
        }.GetNewClosure()
        $crashes = [System.Collections.Generic.List[string]]::new()
        $out = Invoke-PkRunspaceJobs -MaxParallel $Workers -JobParams $jobs -WorkerScript $worker `
            -PollCallback $poll -JobCrashedHandler { param($err) $crashes.Add([string]$err) }.GetNewClosure()
        if ($state.GateTimedOut) { Write-Progress2 "round $round gate-timeout" }
        foreach ($c in $crashes) { Write-Progress2 "round $round crash: $c" }
        if ($crashes.Count -gt 0) { $exitCode = 3 }
        Write-Progress2 ("round $round done {0:N0}ms" -f $state.Started.Elapsed.TotalMilliseconds)
    }
} catch {
    Write-Progress2 "error: $_"
    $exitCode = 4
} finally {
    try { Remove-Item -LiteralPath $tempDir -Recurse -Force } catch { }  # best effort; temp dir only
}
exit $exitCode
