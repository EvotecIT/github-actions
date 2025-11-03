param(
    [Parameter(Mandatory)] [string]$Solution,
    [string]$Configuration = 'Release',
    [string]$Verbosity = 'minimal',
    [string]$FrameworksJson = '[]',
    [bool]$EnableCoverage = $true,
    [string]$Sdk = ''
)

$ErrorActionPreference = 'Stop'

# Frameworks: parse only from input; provide OS-based defaults when empty.
$frameworks = @()
try {
    $json = ($FrameworksJson ?? '').Trim()
    if ($json -and $json -ne '[]') {
        $parsed = ConvertFrom-Json -InputObject $json -Depth 10
        if ($parsed -is [string]) {
            if ($parsed.Trim()) { $frameworks = @($parsed.Trim()) }
        } elseif ($parsed -is [System.Collections.IEnumerable]) {
            foreach ($x in $parsed) { if ([string]$x) { $frameworks += ([string]$x) } }
        }
    }
} catch { }

if ($frameworks.Count -eq 0) {
    if ($env:RUNNER_OS -eq 'Windows') { $frameworks = @('net8.0', 'net472') } else { $frameworks = @('net8.0') }
}

function Invoke-DotNetTest {
    param(
        [Parameter(Mandatory)]
        [string]$fw
    )
    $fwArg = if ($fw) { "--framework $fw" } else { '' }
    $fwSafe = if ($fw) { $fw } else { 'all' }
    $subdir = Join-Path -Path 'artifacts/TestResults' -ChildPath ("fw-$fwSafe")
    New-Item -ItemType Directory -Force -Path $subdir | Out-Null
    $logName = "results-$fwSafe.trx"
    $collect = $EnableCoverage ? '--collect:"XPlat Code Coverage"' : ''
    $cmd = "dotnet test `"$Solution`" --configuration $Configuration --verbosity $Verbosity --logger `"console;verbosity=$Verbosity`" --logger `"trx;LogFileName=$logName`" --results-directory `"$subdir`" $collect $fwArg"
    Write-Host $cmd
    $logsDir = Join-Path $PWD 'artifacts/Logs'
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $logPath = Join-Path $logsDir ("dotnet-$fwSafe.log")
    & dotnet test $Solution --configuration $Configuration --verbosity $Verbosity --logger "console;verbosity=$Verbosity" --logger "trx;LogFileName=$logName" --results-directory "$subdir" $collect $fwArg *>&1 | Tee-Object -FilePath $logPath
    $code = $LASTEXITCODE
    $script:FrameworkRuns["$fwSafe"] = @{ Code = $code; Log = $logPath; Subdir = $subdir; RawFramework = $fw }
    return $code
}

$script:FrameworkRuns = @{}
$overall = 0
foreach ($fw in $frameworks) {
    $code = Invoke-DotNetTest -fw $fw
    if ($code -ne 0) { $overall = $code }
}

# Emit counts JSON
$all = Get-ChildItem -Path 'artifacts/TestResults' -Filter *.trx -Recurse -ErrorAction SilentlyContinue
$outDir = Join-Path $PWD 'artifacts/Counts'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$failedTotal = 0
foreach ($trx in $all) {
    $fw = ($trx.Directory.Name -replace '^fw-', ''); if (-not $fw) { $fw = 'all' }
    $total = 0; $failed = 0; $passed = 0; $skipped = 0
    try {
        # Prefer Counters when present (robust across TRX variants)
        $counters = Select-Xml -Path $trx.FullName -XPath "//*[local-name()='Counters']" | Select-Object -First 1
        if ($counters) {
            $n = $counters.Node
            $toInt = { param($v) try { [int]$v } catch { 0 } }
            $total = & $toInt ($n.GetAttribute('total'))
            $passed = & $toInt ($n.GetAttribute('passed'))
            $failed = (& $toInt ($n.GetAttribute('failed'))) + (& $toInt ($n.GetAttribute('error'))) + (& $toInt ($n.GetAttribute('timeout'))) + (& $toInt ($n.GetAttribute('aborted')))
            $skipped = $total - $passed - $failed
            if ($skipped -lt 0) {
                $skipped = (& $toInt ($n.GetAttribute('notExecuted'))) + (& $toInt ($n.GetAttribute('inconclusive'))) + (& $toInt ($n.GetAttribute('warning')))
            }
        } else {
            # Fallback to per-test outcomes
            $nodes = Select-Xml -Path $trx.FullName -XPath "//*[local-name()='UnitTestResult']"
            foreach ($n in $nodes) {
                $total++
                $outcome = $n.Node.outcome; if (-not $outcome) { $outcome = $n.Node.GetAttribute('outcome') }
                switch ($outcome) {
                    'Passed' { $passed++ }
                    'Failed' { $failed++ }
                    'Error' { $failed++ }
                    'Timeout' { $failed++ }
                    'Aborted' { $failed++ }
                    default { $skipped++ }
                }
            }
            if ($total -eq 0) {
                # Last-resort textual scan
                $raw = Get-Content -Raw -LiteralPath $trx.FullName
                $failed += ([regex]::Matches($raw, 'outcome="(Failed|Error|Timeout|Aborted)"', 'IgnoreCase')).Count
                $passed += ([regex]::Matches($raw, 'outcome="Passed"', 'IgnoreCase')).Count
                $total = $failed + $passed
            }
        }
    } catch { }
    $obj = [ordered]@{ kind = 'dotnet'; os = "$env:RUNNER_OS"; sdk = $Sdk; framework = $fw; total = $total; passed = $passed; failed = $failed; skipped = $skipped }
    $jsonPath = Join-Path $outDir ("dotnet-$($env:RUNNER_OS)-$Sdk-$fw.json")
    ($obj | ConvertTo-Json -Depth 4) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
    $failedTotal += $failed
}

# Prefer dotnet exit code; but if dotnet returned 0 and TRX shows failures, fail the step.
# Enforce failure when any failed tests were detected in TRX
if ($failedTotal -gt 0) {
    Write-Error "Detected $failedTotal failed test(s) across TRX files. Failing step."
    exit 1
}

# Emit build/test error JSON for frameworks that failed before producing TRX
foreach ($key in $script:FrameworkRuns.Keys) {
    $info = $script:FrameworkRuns[$key]
    $fwRaw = [string]$info.RawFramework
    if ($info.Code -ne 0) {
        $expectedTrx = Join-Path $info.Subdir "results-$key.trx"
        if (-not (Test-Path $expectedTrx)) {
            try {
                $msg = ''
                if (Test-Path $info.Log) {
                    $errs = Select-String -Path $info.Log -Pattern '(^CSC\s*:.*error)|(error\s+[A-Z]*\d+)|(^Test Run Aborted)' -SimpleMatch:$false -AllMatches -ErrorAction SilentlyContinue
                    if ($errs) {
                        $msg = ($errs | Select-Object -First 3 | ForEach-Object { $_.Line.Trim() }) -join '; '
                    } else {
                        $tail = Get-Content -LiteralPath $info.Log -Tail 20 -ErrorAction SilentlyContinue
                        $msg = ($tail -join ' ')
                    }
                }
                $obj = [ordered]@{ kind = 'dotnet-error'; os = "$env:RUNNER_OS"; sdk = $Sdk; framework = $fwRaw; message = $msg }
                $jsonPath = Join-Path $outDir ("dotnet-error-$($env:RUNNER_OS)-$Sdk-$key.json")
                ($obj | ConvertTo-Json -Depth 5) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
            } catch { }
        }
    }
}

exit $overall
