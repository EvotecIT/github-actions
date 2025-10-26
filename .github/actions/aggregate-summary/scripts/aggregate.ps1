param(
  [string]$ArtifactsRoot = 'artifacts',
  [string]$SummaryMarker = 'evotec-ci-aggregate-summary'
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $PWD $ArtifactsRoot
if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }

$md = ""
$failed = 0
$jobIssues = @()
$totalAll = 0; $failedAll = 0; $passedAll = 0; $skippedAll = 0

# Job results (failure/cancelled)
$results = @{
  '.NET (Windows)'      = $env:RES_DOTNET_WINDOWS
  '.NET (Ubuntu)'       = $env:RES_DOTNET_UBUNTU
  '.NET (macOS)'        = $env:RES_DOTNET_MACOS
  'PowerShell (Windows)'= $env:RES_PESTER_WINDOWS
}
foreach ($k in $results.Keys) {
  $v = ($results[$k] ?? '').ToLowerInvariant()
  if ($v -in @('failure','cancelled')) { $jobIssues += ("- ❌ {0}: {1}" -f $k, $v) }
}

# .NET TRX parsing
$trxFiles = Get-ChildItem -Recurse -Path $root -Filter *.trx -ErrorAction SilentlyContinue
if ($trxFiles) {
  $md += "### .NET`n"
  $netTotal = 0; $netFailed = 0; $netPassed = 0; $netSkipped = 0
  foreach ($trx in $trxFiles) {
    try {
      $all = Select-Xml -Path $trx.FullName -XPath "//UnitTestResult"
      $nodes = @($all | Where-Object { $_.Node.outcome -in @('Failed','Error','Timeout','Aborted') })
      $passed = @($all | Where-Object { $_.Node.outcome -eq 'Passed' })
      $skipped = @($all | Where-Object { $_.Node.outcome -in @('NotExecuted','Inconclusive','Skipped','Warning') })
      $netTotal += $all.Count; $netFailed += $nodes.Count; $netPassed += $passed.Count; $netSkipped += $skipped.Count
      $groupTitle = [System.IO.Path]::GetFileNameWithoutExtension($trx.Name)
      $printed = $false
      foreach ($n in $nodes) {
        if (-not $printed) { $md += "#### $groupTitle`n"; $printed = $true }
        $name = $n.Node.testName
        $msg  = $n.Node.Output.ErrorInfo.Message
        $md += "- ❌ $name`n"
        if ($msg) { $md += "  - $msg`n" }
        $failed++
      }
    } catch { }
  }
  $totalAll += $netTotal; $failedAll += $netFailed; $passedAll += $netPassed; $skippedAll += $netSkipped
} else {
  $md += "### .NET`n- ℹ️ No .NET test results found`n"
}

# Pester NUnit XML parsing
$nunitFiles = Get-ChildItem -Recurse -Path $root -Filter TestResults.xml -ErrorAction SilentlyContinue
if ($nunitFiles) {
  $md += "### PowerShell (Pester)`n"
  $psTotal = 0; $psFailed = 0; $psPassed = 0; $psSkipped = 0
  foreach ($xmlPath in $nunitFiles) {
    try {
      [xml]$xml = Get-Content -LiteralPath $xmlPath.FullName
      $cases = @($xml.SelectNodes('//test-case'))
      $groupTitle = Split-Path -Leaf -Path (Split-Path -Parent -Path $xmlPath.FullName)
      $printed = $false
      foreach ($c in $cases) { $psTotal++ }
      foreach ($c in $cases) {
        $result = ($c.result + '')
        if ($result -in @('Failure','Error')) {
          if (-not $printed) { $md += "#### $groupTitle`n"; $printed = $true }
          $name = $c.name
          $msg = $c.failure.message.'#text'
          $md += "- ❌ $name`n"
          if ($msg) { $md += "  - $msg`n" }
          $failed++; $psFailed++
        } elseif ($result -eq 'Passed') {
          $psPassed++
        } elseif ($result -in @('Skipped','Ignored','Inconclusive')) {
          $psSkipped++
        }
      }
    } catch { }
  }
  $totalAll += $psTotal; $failedAll += $psFailed; $passedAll += $psPassed; $skippedAll += $psSkipped
} else {
  $md += "### PowerShell (Pester)`n- ℹ️ No Pester test results found`n"
}

if ($jobIssues.Count -gt 0) {
  $md = "## CI Status`n" + ($jobIssues -join "`n") + "`n`n" + $md
  $failed++
}

$header = "## CI Failing Tests Summary";
if ($totalAll -gt 0) {
  $header += (" — {0} failed, {1} passed, {2} skipped ({3} total)" -f $failedAll, $passedAll, $skippedAll, $totalAll)
}

# Per-matrix totals table from counts JSON (if present)
$countFiles = Get-ChildItem -Recurse -Path $root -Filter *.json -ErrorAction SilentlyContinue
$rows = @()
foreach ($cf in $countFiles) {
  try {
    $j = Get-Content -Raw -LiteralPath $cf.FullName | ConvertFrom-Json
    if ($j.kind -eq 'dotnet') {
      $mx = "${j.os} | SDK ${j.sdk} | ${j.framework}" -replace '\|','\\|'
      $rows += [pscustomobject]@{ Job = '.NET'; Matrix = $mx; Passed = $j.passed; Failed = $j.failed; Skipped = $j.skipped; Total = $j.total }
    } elseif ($j.kind -eq 'pester') {
      $mx = "Windows | PS ${j.ps}" -replace '\|','\\|'
      $rows += [pscustomobject]@{ Job = 'PowerShell'; Matrix = $mx; Passed = $j.passed; Failed = $j.failed; Skipped = $j.skipped; Total = $j.total }
    }
  } catch { }
}
if ($rows.Count -gt 0) {
  $mdTable = "| Job | Matrix | Passed | Failed | Skipped | Total |`n|---|---|---:|---:|---:|---:|`n"
  foreach ($r in $rows) { $mdTable += ("| {0} | {1} | {2} | {3} | {4} | {5} |`n" -f $r.Job, $r.Matrix, $r.Passed, $r.Failed, $r.Skipped, $r.Total) }
  $md = $header + "`n`n" + $mdTable + "`n" + $md
} else {
  $md = $header + "`n`n" + $md
}
if ($totalAll -gt 0 -and $failedAll -eq 0 -and $jobIssues.Count -eq 0) { $md += "All tests passed ✅`n" }

if ($env:GITHUB_STEP_SUMMARY) { $md | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append }
"markdown<<EOF`n$md`nEOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"hasfailures=$([string]([bool]($failed -gt 0)))" | Out-File -FilePath $env:GITHUB_OUTPUT -Append

