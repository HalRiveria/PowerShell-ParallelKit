# Force-kill check: are a script's programs killed with it when PowerShell
# itself is killed outright (Task Manager's End task, Stop-Process -Force)?
# No cleanup code runs then; only the kit's Job Object stands between the
# programs and running on as orphans.
#
# Each round starts a host script that runs -JobsPerRound `cmd /c ping` jobs
# through Start-PkProcess (so each job is cmd.exe with ping.exe as its child),
# waits until every ping is running, kills the host with taskkill /F (the
# host only, not its tree), and counts the pings still alive. Any survivor is
# killed so nothing is left behind.
#
#   powershell -NoProfile -File .\Testing\force-kill\run.ps1
#   pwsh -NoProfile -File .\Testing\force-kill\run.ps1
#
# Expected: 0 survivors. Takes about a minute with the defaults.
param([int]$Rounds = 15, [int]$JobsPerRound = 20, [string]$KitPath = (Join-Path $PSScriptRoot '..\..\ParallelKit.ps1'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$KitPath = (Resolve-Path -LiteralPath $KitPath).ProviderPath
$work = Join-Path ([IO.Path]::GetTempPath()) ("pk-force-kill-" + $PID)
$null = New-Item -ItemType Directory -Path $work -Force
$hostScript = Join-Path $work 'host.ps1'
@'
param([string]$Kit, [int]$Jobs)
. $Kit
for ($i = 0; $i -lt $Jobs; $i++) {
    $j = Start-PkProcess -FilePath cmd.exe -Arguments '/d /c ping -n 60 127.0.0.1 >nul'
    [Console]::Out.WriteLine($j['Proc'].Id)
}
[Console]::Out.WriteLine('READY'); [Console]::Out.Flush()
Start-Sleep -Seconds 120
'@ | Set-Content -LiteralPath $hostScript -Encoding ASCII

Write-Host ("PowerShell " + $PSVersionTable.PSVersion + ", kit: " + $KitPath)
$exe = (Get-Process -Id $PID).Path
$survivors = 0; $pings = 0
try {
    for ($round = 1; $round -le $Rounds; $round++) {
        $psi = [Diagnostics.ProcessStartInfo]::new($exe, ('-NoProfile -ExecutionPolicy Bypass -File "' + $hostScript + '" -Kit "' + $KitPath + '" -Jobs ' + $JobsPerRound))
        $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
        $hp = [Diagnostics.Process]::Start($psi)
        $cmdIds = @()
        while ($true) {
            $line = $hp.StandardOutput.ReadLine()
            if ($null -eq $line -or $line -eq 'READY') { break }
            $cmdIds += [int]$line
        }
        # Each cmd.exe's ping.exe, once it's running.
        $pingIds = @()
        foreach ($c in $cmdIds) {
            $p = $null
            for ($t = 0; $t -lt 40 -and -not $p; $t++) {
                $p = Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $c + " AND Name='PING.EXE'")
                if (-not $p) { Start-Sleep -Milliseconds 25 }
            }
            if ($p) { $pingIds += [int]@($p)[0].ProcessId }
        }
        $null = & taskkill.exe /F /PID $hp.Id 2>&1   # the host only, not its tree
        $null = $hp.WaitForExit(10000); $hp.Dispose()
        Start-Sleep -Milliseconds 1500
        $roundSurvivors = 0
        foreach ($id in $pingIds) {
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) {
                $roundSurvivors++
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        }
        $pings += $pingIds.Count; $survivors += $roundSurvivors
        Write-Host ("round " + $round + ": " + $pingIds.Count + " of " + $JobsPerRound + " pings seen, " + $roundSurvivors + " survived")
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
$color = if ($survivors -eq 0) { 'Green' } else { 'Red' }
Write-Host ("force-killed host: " + $survivors + " of " + $pings + " pings survived (" + $Rounds + " rounds)") -ForegroundColor $color
if ($survivors -gt 0) { exit 1 }
