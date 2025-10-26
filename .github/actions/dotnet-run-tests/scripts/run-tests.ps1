param(
  [Parameter(Mandatory)] [string]$Solution,
  [string]$Configuration = 'Release',
  [string]$Verbosity = 'minimal',
  [string]$FrameworksJson = '[]',
  [bool]$EnableCoverage = $true,
  [string]$Sdk = ''
)

$ErrorActionPreference = 'Stop'

# Determine frameworks: use input or auto-detect from *.Tests.csproj
$frameworks = @()
try { if ($FrameworksJson -and $FrameworksJson -ne '[]') { $frameworks = ConvertFrom-Json -InputObject $FrameworksJson } } catch { }
if ($frameworks.Count -eq 0) {
  $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $testProjects = Get-ChildItem -Recurse -Path . -Filter *.csproj | Where-Object { $_.Name -match '\.Tests\.csproj$' }
  foreach ($proj in $testProjects) {
    try {
      [xml]$xml = Get-Content -LiteralPath $proj.FullName
      $tfs = @();
      $tfs += ($xml.Project.PropertyGroup.TargetFrameworks | ForEach-Object { $_.InnerText })
      $tfs += ($xml.Project.PropertyGroup.TargetFramework  | ForEach-Object { $_.InnerText })
      foreach ($tf in ($tfs -split ';' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })) { [void]$set.Add($tf) }
    } catch { }
  }
  $frameworks = @($set)
  if ($env:RUNNER_OS -ne 'Windows') { $frameworks = @($frameworks | Where-Object { $_ -notmatch '^net4' }) }
}
if ($frameworks.Count -eq 0) { $frameworks = @('') }

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
    $nodes = Select-Xml -Path $trx.FullName -XPath "//*[local-name()='UnitTestResult']"
    foreach ($n in $nodes) {
      $total++
      $outcome = $n.Node.outcome
      if (-not $outcome) { $outcome = $n.Node.GetAttribute('outcome') }
      switch ($outcome) {
        'Passed' { $passed++ }
        'Failed' { $failed++ }
        'Error'  { $failed++ }
        'Timeout' { $failed++ }
        'Aborted' { $failed++ }
        default { $skipped++ }
      }
    }
  } catch { }
  $obj = [ordered]@{ kind='dotnet'; os="$env:RUNNER_OS"; sdk=$Sdk; framework=$fw; total=$total; passed=$passed; failed=$failed; skipped=$skipped }
  $jsonPath = Join-Path $outDir ("dotnet-$($env:RUNNER_OS)-$Sdk-$fw.json")
  ($obj | ConvertTo-Json -Depth 4) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
  $failedTotal += $failed
}

if ($overall -eq 0 -and $failedTotal -gt 0) { exit 1 } else { exit $overall }
