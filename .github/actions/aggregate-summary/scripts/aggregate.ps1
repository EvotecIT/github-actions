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

# Friendly TFM display mapper
$tfmMap = {
  param($tfm)
  if (-not $tfm) { return '' }
  if ($tfm -match '^netstandard(\d+)\.(\d+)$') { return "NetStandard$($Matches[1]).$($Matches[2])" }
  if ($tfm -match '^net(\d+)\.(\d+)$') { return "Net$($Matches[1]).$($Matches[2])" }
  if ($tfm -match '^net(\d)(\d)(\d)$') { return "NetFramework$($Matches[1]).$($Matches[2]).$($Matches[3])" }
  return $tfm
}

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
      $all = Select-Xml -Path $trx.FullName -XPath "//*[local-name()='UnitTestResult']"
      $nodes = @()
      $passed = @()
      $skipped = @()
      foreach ($i in $all) {
        $outcome = $i.Node.outcome
        if (-not $outcome) { $outcome = $i.Node.GetAttribute('outcome') }
        if ($outcome -in @('Failed','Error','Timeout','Aborted')) { $nodes += ,$i }
        elseif ($outcome -eq 'Passed') { $passed += ,$i }
        elseif ($outcome -in @('NotExecuted','Inconclusive','Skipped','Warning')) { $skipped += ,$i }
      }
      $netTotal += $all.Count; $netFailed += $nodes.Count; $netPassed += $passed.Count; $netSkipped += $skipped.Count
      $groupTitle = [System.IO.Path]::GetFileNameWithoutExtension($trx.Name)
      $printed = $false
      foreach ($n in $nodes) {
        if (-not $printed) { $md += "#### $groupTitle`n"; $printed = $true }
        $name = $n.Node.testName
        if (-not $name) { $name = $n.Node.GetAttribute('testName') }
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
# Prefer TRX/NUnit-derived totals; if none, fall back to counts table totals
$rowsFailedSum = 0; $rowsPassedSum = 0; $rowsSkippedSum = 0; $rowsTotalSum = 0
try {
  $rowsFailedSum  = ($rows  | Measure-Object -Property Failed  -Sum).Sum
  $rowsPassedSum  = ($rows  | Measure-Object -Property Passed  -Sum).Sum
  $rowsSkippedSum = ($rows  | Measure-Object -Property Skipped -Sum).Sum
  $rowsTotalSum   = ($rows  | Measure-Object -Property Total   -Sum).Sum
} catch { }
$hFailed  = $failedAll; $hPassed = $passedAll; $hSkipped = $skippedAll; $hTotal = $totalAll
if ($hTotal -le 0 -and $rowsTotalSum -gt 0) {
  $hFailed = $rowsFailedSum; $hPassed = $rowsPassedSum; $hSkipped = $rowsSkippedSum; $hTotal = $rowsTotalSum
}
if ($hTotal -gt 0) { $header += (" — {0} failed, {1} passed, {2} skipped ({3} total)" -f $hFailed, $hPassed, $hSkipped, $hTotal) }

# Per-matrix totals table from counts JSON (if present)
$countFiles = Get-ChildItem -Recurse -Path $root -Filter *.json -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'artifacts[/\\]Counts' }
$rows = @()
$pesterNoteRows = @()
${global:DotnetMissingNotes} = @()
foreach ($cf in $countFiles) {
  try {
    $j = Get-Content -Raw -LiteralPath $cf.FullName | ConvertFrom-Json
    if ($j.kind -eq 'dotnet') {
      $os = "$($j.os)"; $sdk = "$($j.sdk)"; $fw = "$($j.framework)"
      if (-not $os -or -not $sdk -or ($null -eq $fw)) {
        # Fallback: infer from filename like dotnet-OS-SDK-fw.json
        $name = [System.IO.Path]::GetFileNameWithoutExtension($cf.Name) # e.g., dotnet-Windows-8.0.x-all
        $parts = $name -split '-'
        if ($parts.Length -ge 4) {
          $os  = $os  ? $os  : $parts[1]
          $sdk = $sdk ? $sdk : $parts[2]
          $fw  = ($fw  -ne $null -and $fw -ne '') ? $fw : ($parts[3])
        }
      }
      $fwDisp = & $tfmMap $fw
      $mx = ("{0} | SDK {1} | {2}" -f $os,$sdk,$fwDisp) -replace '\|','\\|'
      $rows += [pscustomobject]@{ Job = '.NET'; Matrix = $mx; Passed = $j.passed; Failed = $j.failed; Skipped = $j.skipped; Total = $j.total }
    } elseif ($j.kind -eq 'pester') {
      $psv = "$($j.ps)"; if (-not $psv) { $psv = 'unknown' }
      $mx = ("Windows | PS {0}" -f $psv) -replace '\|','\\|'
      $rows += [pscustomobject]@{ Job = 'PowerShell'; Matrix = $mx; Passed = $j.passed; Failed = $j.failed; Skipped = $j.skipped; Total = $j.total }
      if ($j.total -eq 0 -and $j.PSObject.Properties.Name -contains 'note' -and $j.note) {
        $pesterNoteRows += [pscustomobject]@{ Version = $psv; Note = [string]$j.note }
      }
    } elseif ($j.kind -eq 'dotnet-notes') {
      $missing = @($j.missing_for_tests | ForEach-Object { & $tfmMap $_ })
      if ($missing.Count -gt 0) {
        ${global:DotnetMissingNotes} += [pscustomobject]@{ OS=$j.os; SDK=$j.sdk; Missing=$missing }
      }
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
$noteLines = @()
foreach ($p in $pesterNoteRows) { $noteLines += ("- ℹ️ PowerShell {0}: {1}" -f $p.Version, $p.Note) }
if ($noteLines.Count -gt 0) { $md += "`n### PowerShell (Pester) — No tests detected`n" + ($noteLines -join "`n") + "`n" }

# Notes about .NET frameworks not exercised by the tests
if (${global:DotnetMissingNotes} -and ${global:DotnetMissingNotes}.Count -gt 0) {
  $md += "`n### .NET — Frameworks not tested`n"
  foreach ($n in ${global:DotnetMissingNotes}) {
    $md += ("- {0} | SDK {1}: {2}`n" -f $n.OS,$n.SDK,($n.Missing -join ', '))
  }
}
# Decide final status using both TRX scan and counts table totals
$rowsTotal = 0
try { $rowsTotal = ($rows | Measure-Object -Property Total -Sum).Sum } catch { $rowsTotal = 0 }
if ((($totalAll + $rowsTotal) -gt 0) -and ($failedAll + $rowsFailedSum) -eq 0 -and $jobIssues.Count -eq 0) { $md += "All tests passed ✅`n" }

if ($env:GITHUB_STEP_SUMMARY) { $md | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append }
"markdown<<EOF`n$md`nEOF" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
"hasfailures=$([string]([bool]($failed -gt 0)))" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
