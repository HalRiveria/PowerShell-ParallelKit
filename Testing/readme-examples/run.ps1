# README examples check: do the code examples in README.md run, and do what
# the README says they do?
#
# Each example is read straight out of README.md (found by a line of text it
# contains, so the check follows the README as it changes), saved as its own
# script with only the kit's path and the data folder filled in, and run in a
# fresh PowerShell of the same kind as this one, once without StrictMode and
# once with it. Checks after each one confirm what it did. The group-dispatch
# example also runs with an abort that lets running jobs finish and one that
# kills them. One more check covers the README's note that on 5.1 a worker's
# $ErrorActionPreference doesn't reach Get-FileHash.
#
#   powershell -NoProfile -File .\Testing\readme-examples\run.ps1
#   pwsh -NoProfile -File .\Testing\readme-examples\run.ps1
#
# The examples convert images with cjxl.exe (libjxl's JPEG XL encoder), so it
# has to be on PATH. Expected: ALL PASSED. Takes under a minute. -ReadmePath
# checks a draft instead of README.md.
param(
    [string]$ReadmePath = (Join-Path $PSScriptRoot '..\..\README.md'),
    [string]$KitPath = (Join-Path $PSScriptRoot '..\..\ParallelKit.ps1')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReadmePath = (Resolve-Path -LiteralPath $ReadmePath).ProviderPath
$KitPath = (Resolve-Path -LiteralPath $KitPath).ProviderPath
if (-not (Get-Command cjxl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host 'cjxl.exe is not on PATH. The README examples convert PNGs with it: install libjxl (for example, winget install libjxl) and run this again.'
    exit 2
}

# Every ```powershell block in the README, its indentation removed.
function Get-ReadmeBlocks {
    param([string]$Path)
    $blocks = [System.Collections.Generic.List[string]]::new()
    $lines = [IO.File]::ReadAllLines($Path)
    $i = 0
    while ($i -lt $lines.Length) {
        $m = [regex]::Match($lines[$i], '^(\s*)```powershell\s*$')
        $i++
        if (-not $m.Success) { continue }
        $indent = $m.Groups[1].Value.Length
        $body = [System.Collections.Generic.List[string]]::new()
        while ($i -lt $lines.Length -and $lines[$i] -notmatch '^\s*```\s*$') {
            $l = $lines[$i]
            if ($l.Length -ge $indent -and $l.Substring(0, $indent).Trim() -eq '') { $l = $l.Substring($indent) }
            $body.Add($l); $i++
        }
        $i++
        $blocks.Add(($body -join "`r`n"))
    }
    return $blocks
}

$blocks = Get-ReadmeBlocks -Path $ReadmePath
function Get-Example {
    # The one block holding this text. A miss means the README changed: update the marker.
    param([string]$Marker)
    $found = @($blocks | Where-Object { $_.Contains($Marker) })
    if ($found.Count -ne 1) { throw ("README examples check: expected one code block in README.md containing '" + $Marker + "', found " + $found.Count + ". If the example changed, update its marker in this script.") }
    # Ends with a line break, like each piece it's joined to: a here-string has none of its own.
    return $found[0].Replace('"$PSScriptRoot\ParallelKit.ps1"', '$Kit') + "`r`n"
}

# Set up at the top of every test script: the data folder, a few PNGs and a
# broken one, and a check function.
$prelude = @'
param([string]$Kit, [string]$Data, [switch]$Strict)
if ($Strict) { Set-StrictMode -Version Latest }
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Test-Check([bool]$Ok, [string]$What) { if ($Ok) { "[PASS] $What" } else { "[FAIL] $What"; $script:fails++ } }
Add-Type -AssemblyName System.Drawing
function New-TestPng([string]$Path, [int]$Size) {
    # Random pixels, so a big one takes cjxl a moment.
    $bmp = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $rect = [System.Drawing.Rectangle]::new(0, 0, $Size, $Size)
    $bits = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, $bmp.PixelFormat)
    $bytes = [byte[]]::new($bits.Stride * $Size)
    [System.Random]::new($Path.Length).NextBytes($bytes)
    [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $bits.Scan0, $bytes.Length)
    $bmp.UnlockBits($bits)
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$null = New-Item -ItemType Directory -Path $Data -Force
Set-Location -LiteralPath $Data
'@
$pngs = @'
foreach ($n in 'a', 'b', 'c') { New-TestPng (Join-Path $Data "$n.png") 32 }
Set-Content -LiteralPath (Join-Path $Data 'bad.png') -Value 'not a png'

'@
$ending = @'

Set-Location -LiteralPath ([IO.Path]::GetTempPath())
exit $script:fails
'@

$tests = [System.Collections.Generic.List[hashtable]]::new()

$tests.Add(@{ Name = 'Quick start'; Body = $pngs + (Get-Example 'Invoke-PkProcessBatch -Commands $commands -MaxConcurrent 6') + @'

Test-Check ($batch.Results.Count -eq 4) "a result per command ($($batch.Results.Count) of 4)"
Test-Check (@($batch.Results | Where-Object { $_.ExitCode -eq 0 }).Count -eq 3) 'the three good PNGs converted'
Test-Check (@(Get-ChildItem -Filter *.png.jxl).Count -eq 3) 'three .png.jxl files written'
Test-Check (@($batch.Results | Where-Object { $_.ExitCode -ne 0 }).Count -eq 1) 'bad.png is the one failure'
$top = @($batch.Results | Sort-Object Duration -Descending | Select-Object -First 10)
Test-Check ($top.Count -eq 4 -and $top[0].Duration -is [TimeSpan]) 'the Sort-Object Duration line works'
'@ })

$tests.Add(@{ Name = 'Setup'; Body = (Get-Example '$pk = Initialize-ParallelKit') + @'

Test-Check ($null -ne $pk -and $pk.StartMode -eq 'CreatedInJob') "Initialize-ParallelKit's result read (StartMode $($pk.StartMode))"
'@ })

$tests.Add(@{ Name = 'Run a list of programs'; Body = $pngs + @'
. $Kit
$global:messages = [System.Collections.Generic.List[string]]::new()
Set-PkMessageHandler { param($Message, $Level) $global:messages.Add("$Level $Message") }

'@ + (Get-Example '$batchParams = @{') + @'

Test-Check ($batch.Results.Count -eq 4) "a result per command ($($batch.Results.Count) of 4)"
Test-Check (@($batch.Results | Where-Object { $_.Command.Source -is [System.IO.FileInfo] }).Count -eq 4) 'Source comes back on each result''s Command'
Test-Check (@($global:messages | Where-Object { $_ -eq 'Error FAILED: bad.png' }).Count -eq 1) "-OnComplete reported bad.png ($($global:messages -join '; '))"
Test-Check (@($global:messages | Where-Object { $_ -like 'Warn *' }).Count -eq 1 -and @($global:messages | Where-Object { $_ -match '^Warn bad\.png: exit code [1-9]' }).Count -eq 1) "the results loop lists bad.png, and only it ($($global:messages -join '; '))"
$n = 0; $indexed = foreach ($c in $commands) { $c2 = $c.Clone(); $c2.Index = $n++; $c2 }
$again = Invoke-PkProcessBatch -Commands $indexed -MaxConcurrent 6
Test-Check ((@($again.Results | Sort-Object { $_.Command.Index }) | ForEach-Object { $_.Command.Index }) -join ',' -eq '0,1,2,3') 'the Index sort line puts results back in order'
Set-PkMessageHandler $null
'@ })

$tests.Add(@{ Name = 'Run PowerShell code in parallel'; Body = $pngs + ". `$Kit`r`n" + (Get-Example 'function Get-FileSha') + @'

$expected = @{}; foreach ($f in Get-ChildItem -File) { $expected[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
Test-Check ($shaByPath.Count -eq $expected.Count) "a hash per file ($($shaByPath.Count) of $($expected.Count))"
Test-Check (@($expected.Keys | Where-Object { $shaByPath[$_] -ne $expected[$_] }).Count -eq 0) 'every hash matches Get-FileHash'
Test-Check ($out.CrashedCount -eq 0 -and -not $out.Aborted) 'no crashes, not aborted'
'@ })

$tests.Add(@{ Name = 'Worker that returns its own error object'; Body = $pngs + @'
. $Kit
$global:results = [System.Collections.Generic.List[object]]::new()
$jobsParams = @{
    MaxParallel   = 2
    JobParams     = @(@{ Path = (Join-Path $Data 'a.png') }, @{ Path = (Join-Path $Data 'missing.png') })
    ResultHandler = { param($r) $global:results.Add($r) }

'@ + (Get-Example 'Error = $_.Exception.Message') + @'

}
$out = Invoke-PkRunspaceJobs @jobsParams
Test-Check ($global:results.Count -eq 2) "a result per job ($($global:results.Count) of 2)"
$good = @($global:results | Where-Object { $_.Path -like '*a.png' })[0]
$missing = @($global:results | Where-Object { $_.Path -like '*missing.png' })[0]
Test-Check ($null -ne $good.Hash -and $null -eq $good.Error) 'an existing file gets a hash and no error'
Test-Check ($null -eq $missing.Hash -and $missing.Error -like '*missing.png*') "a missing file gets an error object ($($missing.Error))"
Test-Check ($out.CrashedCount -eq 0) 'nothing counted as a crash'
'@ })

$tests.Add(@{ Name = 'Messages'; Body = @'
. $Kit
$global:log = [System.Collections.Generic.List[string]]::new()
function Write-MyLog($Message, $Level) { $global:log.Add("$Level|$Message") }

'@ + (Get-Example 'Set-PkMessageHandler { param($Message, $Level)') + @'

$null = Invoke-PkRunspaceJobs -MaxParallel 2 -JobParams @(@{ N = 1 }) -WorkerScript { param($N) Write-PkMessage "from worker $N" -Level Warning }
Write-PkMessage 'from the main thread' -Level Error
Test-Check ($global:log -contains 'Warn|from worker 1') "a worker's -Level Warning arrives as Warn ($($global:log -join '; '))"
Test-Check ($global:log -contains 'Error|from the main thread') 'a main-thread message arrives'
Set-PkMessageHandler $null
'@ })

# The group-dispatch example, three ways. Its folder is the data folder.
$group = (Get-Example '$dispatchParams = @{').Replace("'D:\Scans'", '$Data')
$abortAfterFive = '$abortAt = @{ n = 0 }; $dispatchParams.PollCallback = { if (++$abortAt.n -eq 5) { Request-PkAbort } }' + "`r`n"
$dispatchLine = '$dispatch = Invoke-PkRun'
if (-not $group.Contains($dispatchLine)) { throw "README examples check: the group-dispatch example no longer has the line '$dispatchLine', which the abort tests hook into. Update this script." }

$tests.Add(@{ Name = 'Process dispatch with groups'; Body = @'
$a = New-Item -ItemType Directory -Path (Join-Path $Data 'A'); 0..3 | ForEach-Object { New-TestPng (Join-Path $a "p$_.png") 64 }
$b = New-Item -ItemType Directory -Path (Join-Path $Data 'B'); 0..2 | ForEach-Object { New-TestPng (Join-Path $b "p$_.png") 64 }
Set-Content -LiteralPath (Join-Path $b 'bad.png') -Value 'not a png'
$null = New-Item -ItemType Directory -Path (Join-Path $Data 'C empty')
$d = New-Item -ItemType Directory -Path (Join-Path $Data 'D [x]'); 0..1 | ForEach-Object { New-TestPng (Join-Path $d "p$_.png") 64 }

'@ + $group + @'

Test-Check (-not $dispatch.Aborted) 'not aborted'
Test-Check (@($dispatch.GroupResults).Count -eq 4) "a result per folder ($(@($dispatch.GroupResults).Count) of 4)"
Test-Check (Test-Path -LiteralPath (Join-Path $Data 'A.zip')) 'folder A zipped'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $Data 'A.zip')); $entries = $zip.Entries.Count; $zip.Dispose()
Test-Check ($entries -eq 4) "A.zip holds its four .jxl files ($entries)"
Test-Check (-not (Test-Path -LiteralPath (Join-Path $Data 'B.zip'))) 'folder B, with a bad file, not zipped'
Test-Check ($failed[(Join-Path $Data 'B')] -eq 1) 'B counts one failure, after its retry'
Test-Check (-not (Test-Path -LiteralPath (Join-Path $Data 'C empty.zip'))) 'the empty folder not zipped'
Test-Check (Test-Path -LiteralPath (Join-Path $Data 'D [x].zip')) 'a folder with brackets in its name zipped'
'@ })

$bigFolder = @'
$a = New-Item -ItemType Directory -Path (Join-Path $Data 'A'); 0..29 | ForEach-Object { New-TestPng (Join-Path $a ("p{0:D2}.png" -f $_)) 1200 }
# A file a job that never starts would write: an abort's cleanup must leave it alone.
Set-Content -LiteralPath (Join-Path $a 'p29.jxl') -Value 'SENTINEL'
$b = New-Item -ItemType Directory -Path (Join-Path $Data 'B'); 0..1 | ForEach-Object { New-TestPng (Join-Path $b "p$_.png") 64 }

'@
$abortChecks = @'

Test-Check ([bool]$dispatch.Aborted) 'aborted'
$ga = @($dispatch.GroupResults | Where-Object { $_.GroupInfo.Name -eq 'A' })
Test-Check ($ga.Count -eq 1 -and $ga[0].Aborted) 'folder A marked Aborted'
Test-Check (-not (Test-Path -LiteralPath (Join-Path $Data 'A.zip'))) 'folder A not zipped'
Test-Check (-not (Test-Path -LiteralPath (Join-Path $Data 'B.zip'))) 'folder B not zipped'
Test-Check ((Get-Content -LiteralPath (Join-Path $a 'p29.jxl') -Raw).Trim() -eq 'SENTINEL') 'a never-started job''s existing file left alone'

'@

$tests.Add(@{ Name = 'Process dispatch with groups, Ctrl+C that lets running jobs finish'; Body = $bigFolder + $group.Replace($dispatchLine, $abortAfterFive + $dispatchLine) + $abortChecks + @'
$jxl = @(Get-ChildItem -LiteralPath $a -Filter *.jxl).Count
Test-Check ($jxl -gt 1 -and $jxl -lt 30) "the running jobs finished, the rest never started ($($jxl - 1) of 29 converted)"
'@ })

$tests.Add(@{ Name = 'Process dispatch with groups, Ctrl+C that kills running jobs'; Body = @'
'@ + $bigFolder + @'
# Stand-ins for partial output where the first six jobs, the ones running when they're killed, write.
0..5 | ForEach-Object { Set-Content -LiteralPath (Join-Path $a ("p{0:D2}.jxl" -f $_)) -Value 'STALE' }

'@ + $group.Replace($dispatchLine, $abortAfterFive + '$dispatchParams.AbortTimeoutSeconds = 0' + "`r`n" + $dispatchLine) + $abortChecks + @'
Test-Check ($dispatch.ForceKilledCount -gt 0) "running jobs force-killed ($($dispatch.ForceKilledCount))"
# A job that finished before the abort replaced its stand-in with real output, which stays.
$left = @(0..5 | Where-Object { $p = Join-Path $a ("p{0:D2}.jxl" -f $_); (Test-Path -LiteralPath $p) -and (Get-Content -LiteralPath $p -Raw) -match 'STALE' })
Test-Check ($left.Count -eq 0) "-JobAbortCleanup removed the killed jobs' files ($($left.Count) of 6 stand-ins left)"
'@ })

# Behind the README's 5.1 note in "Errors and crashed workers". Not an example.
$tests.Add(@{ Name = "Get-FileHash and a worker's `$ErrorActionPreference"; Body = @'
. $Kit
$missingFile = Join-Path $Data 'missing.png'
$global:results = [System.Collections.Generic.List[string]]::new()
$null = Invoke-PkRunspaceJobs -MaxParallel 1 -JobParams @(@{ Path = $missingFile; UseParam = $false }, @{ Path = $missingFile; UseParam = $true }) -ResultHandler { param($r) $global:results.Add($r) } -WorkerScript {
    param($Path, $UseParam)
    $ErrorActionPreference = 'Stop'
    try {
        if ($UseParam) { $null = Get-FileHash -LiteralPath $Path -ErrorAction Stop } else { $null = Get-FileHash -LiteralPath $Path }
        "$UseParam not caught"
    } catch { "$UseParam caught" }
} 2>$null
$isFunction = (Get-Command Get-FileHash).CommandType -eq 'Function'
Test-Check ($global:results -contains 'True caught') '-ErrorAction Stop catches a missing file in a worker'
if ($isFunction) {
    Test-Check ($global:results -contains 'False not caught') "Get-FileHash is a function here, and the worker's preference alone doesn't catch it, as the README says"
} else {
    Test-Check ($global:results -contains 'False caught') 'Get-FileHash is a cmdlet here, and the preference alone catches it'
}
'@ })

$exe = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("pk-readme-examples-" + $PID)
$null = New-Item -ItemType Directory -Path $work -Force
Write-Host ("PowerShell " + $PSVersionTable.PSVersion + ", README: " + $ReadmePath + ", kit: " + $KitPath)
$failures = 0
try {
    $t = 0
    foreach ($test in $tests) {
        $t++
        $script = Join-Path $work ("test" + $t + ".ps1")
        [IO.File]::WriteAllText($script, ($prelude + "`r`n" + $test['Body'] + $ending), [Text.UTF8Encoding]::new($true))
        foreach ($strict in $false, $true) {
            $data = Join-Path $work ("data" + $t + $(if ($strict) { '-strict' } else { '' }))
            $label = $test['Name'] + $(if ($strict) { ', StrictMode' } else { '' })
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Kit', $KitPath, '-Data', $data)
            if ($strict) { $argList += '-Strict' }
            # Native stderr comes back as error records: Continue, or 5.1 stops on the first.
            $ErrorActionPreference = 'Continue'
            $output = @(& $exe @argList 2>&1 | ForEach-Object { [string]$_ })
            $code = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            $checks = @($output | Where-Object { $_ -match '^\[(PASS|FAIL)\]' })
            $failed = @($checks | Where-Object { $_ -like '`[FAIL`]*' })
            if ($code -ne 0 -or $failed.Count -gt 0 -or $checks.Count -eq 0) {
                $failures++
                Write-Host ("[FAIL] " + $label + " (exit " + $code + "). Its output:")
                $output | ForEach-Object { Write-Host ("    " + $_) }
            } else {
                Write-Host ("[PASS] " + $label + " (" + $checks.Count + " checks)")
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures -eq 0) { Write-Host 'ALL PASSED' } else { Write-Host ($failures.ToString() + ' FAILED') }
exit $failures
