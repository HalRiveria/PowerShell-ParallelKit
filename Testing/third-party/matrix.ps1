# Runs the whole stress matrix through run.ps1 and appends each summary line to -Log.
#   powershell -NoProfile -File .\Testing\third-party\matrix.ps1 -Trials 20
param([int]$Trials = 20, [string]$Log = (Join-Path $PSScriptRoot 'results\matrix.log'))
$runner = Join-Path $PSScriptRoot 'run.ps1'
foreach ($exe in 'powershell', 'pwsh') {
    foreach ($tool in 'ThreadJob', 'RSJob') {
        foreach ($main in 'Busy', 'Wait') {
            $combos = @(
                @('JobValue', 'Args'), @('JobValue', 'Using'), @('Delegate', 'Args'), @('Delegate', 'Using'),
                @('TextJobValue', 'Args'), @('TextDelegate', 'Args'))
            foreach ($c in $combos) {
                $line = & powershell -NoProfile -File $runner -Exe $exe -Tool $tool -Case $c[0] -Via $c[1] -Main $main -Trials $Trials
                Add-Content -Path $Log -Value $line
            }
        }
    }
}
Add-Content -Path $Log -Value 'MATRIX DONE'
