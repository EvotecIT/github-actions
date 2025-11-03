param(
  [string]$TestsPath = 'Module/Tests',
  [string]$ResultsFile = 'Module/TestResults.xml',
  [string]$TestScript = ''
)

$ErrorActionPreference = 'Stop'

if ($TestScript) {
  & $TestScript
  exit $LASTEXITCODE
}

$cfg = New-PesterConfiguration
$cfg.Run.Path = $TestsPath
$cfg.Run.Exit = $true
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'NUnitXml'
$cfg.TestResult.OutputPath = $ResultsFile
Invoke-Pester -Configuration $cFfg

