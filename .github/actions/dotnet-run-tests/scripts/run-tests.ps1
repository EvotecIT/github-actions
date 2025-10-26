param(
  [Parameter(Mandatory)] [string]$Solution,
  [string]$Configuration = 'Release',
  [string]$Verbosity = 'minimal',
  [string]$FrameworksJson = '[]',
  [bool]$EnableCoverage = $true,
  [string]$Sdk = ''
)

$ErrorActionPreference = 'Stop'

# Determine frameworks: explicit input or auto-detect
$frameworks = @()
try { if ($FrameworksJson -and $FrameworksJson -ne '[]') { $frameworks = ConvertFrom-Json -InputObject $FrameworksJson } } catch { }

# Detect test project TFMs
$testFrameworks = @()
if ($frameworks.Count -eq 0) {
  $testSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $testProjects = Get-ChildItem -Recurse -Path . -Filter *.csproj | Where-Object { $_.Name -match '\.Tests\.csproj$' }
  foreach ($proj in $testProjects) {
    try {
      [xml]$xml = Get-Content -LiteralPath $proj.FullName
      $tfs = @();
      $tfs += ($xml.Project.PropertyGroup.TargetFrameworks | ForEach-Object { $_.InnerText })
      $tfs += ($xml.Project.PropertyGroup.TargetFramework  | ForEach-Object { $_.InnerText })
      foreach ($tf in ($tfs -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })) { [void]$testSet.Add($tf) }
    } catch { }
  }
  $testFrameworks = @($testSet)
  if ($env:RUNNER_OS -ne 'Windows') { $testFrameworks = @($testFrameworks | Where-Object { $_ -notmatch '^net4' }) }
}

# Detect main library TFMs
$libFrameworks = @()
try {
  $libSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $libProjects = Get-ChildItem -Recurse -Path . -Filter *.csproj | Where-Object { $_.Name -notmatch '\.Tests\.csproj$' }
  foreach ($proj in $libProjects) {
    try {
      [xml]$xml = Get-Content -LiteralPath $proj.FullName
      $tfs = @();
      $tfs += ($xml.Project.PropertyGroup.TargetFrameworks | ForEach-Object { $_.InnerText })
      $tfs += ($xml.Project.PropertyGroup.TargetFramework  | ForEach-Object { $_.InnerText })
      foreach ($tf in ($tfs -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })) { [void]$libSet.Add($tf) }
    } catch { }
  }
  $libFrameworks = @($libSet)
} catch { }

# Choose frameworks to run: tests TFMs (if auto) or provided input
if ($frameworks.Count -eq 0) {
  if ($testFrameworks.Count -gt 0) { $frameworks = $testFrameworks } else { $frameworks = @('') }
}

# Note any library TFMs that are not testable by current test projects
$missingForTests = @()
foreach ($lf in $libFrameworks) { if ($lf -notin $frameworks) { $missingForTests += $lf } }

function Run-Test($fw) {
  $fwArg = if ($fw) { "--framework $fw" } else { '' }
  $fwSafe = if ($fw) { $fw } else { 'all' }
  $subdir = Join-Path -Path 'artifacts/TestResults' -ChildPath ("fw-$fwSafe")
  New-Item -ItemType Directory -Force -Path $subdir | Out-Null
  $logName = "results-$fwSafe.trx"
  $collect = $EnableCoverage ? '--collect:"XPlat Code Coverage"' : ''
  $cmd = "dotnet test `"$Solution`" --configuration $Configuration --no-build --verbosity $Verbosity --logger `"console;verbosity=$Verbosity`" --logger `"trx;LogFileName=$logName`" --results-directory `"$subdir`" $collect $fwArg"
  Write-Host $cmd
  & dotnet test $Solution --configuration $Configuration --no-build --verbosity $Verbosity --logger "console;verbosity=$Verbosity" --logger "trx;LogFileName=$logName" --results-directory "$subdir" $collect $fwArg
  return $LASTEXITCODE
}

$overall = 0
foreach ($fw in $frameworks) {
  $code = Run-Test $fw
  if ($code -ne 0) { $overall = $code }
}

# Emit counts JSON
$all = Get-ChildItem -Path 'artifacts/TestResults' -Filter *.trx -Recurse -ErrorAction SilentlyContinue
$outDir = Join-Path $PWD 'artifacts/Counts'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$failedTotal = 0
foreach ($trx in $all) {
  $fw  = ($trx.Directory.Name -replace '^fw-',''); if (-not $fw) { $fw = 'all' }
  $total = 0; $failed = 0; $passed = 0; $skipped = 0
  try {
    # Prefer Counters when present (robust across TRX variants)
    $counters = Select-Xml -Path $trx.FullName -XPath "//*[local-name()='Counters']" | Select-Object -First 1
    if ($counters) {
      $n = $counters.Node
      $toInt = { param($v) try { [int]$v } catch { 0 } }
      $total  = & $toInt ($n.GetAttribute('total'))
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
          'Error'  { $failed++ }
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
  $obj = [ordered]@{ kind='dotnet'; os="$env:RUNNER_OS"; sdk=$Sdk; framework=$fw; total=$total; passed=$passed; failed=$failed; skipped=$skipped }
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

# Emit a note JSON describing library vs test TFMs for the aggregator
try {
  $outDir = Join-Path $PWD 'artifacts/Counts'
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  $notes = [ordered]@{
    kind = 'dotnet-notes'
    os   = $env:RUNNER_OS
    sdk  = $Sdk
    lib_frameworks      = @($libFrameworks)
    test_frameworks     = @($frameworks)
    missing_for_tests   = @($missingForTests)
  }
  $jsonPath = Join-Path $outDir ("dotnet-notes-$($env:RUNNER_OS)-$Sdk.json")
  ($notes | ConvertTo-Json -Depth 5) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
} catch { }

exit $overall
