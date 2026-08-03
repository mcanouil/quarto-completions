<#
.SYNOPSIS
  End-to-end test for the PowerShell installer.

.DESCRIPTION
  Serves the rendered site locally, installs into a throwaway profile, and
  asserts what landed where, that a second run changes nothing, that a download
  which no longer matches the manifest is refused, and that uninstalling leaves
  no residue. Mirrors tests/install.sh, which covers the POSIX installer.

.EXAMPLE
  pwsh -NoProfile -File tests/install.ps1 docs/_site
#>

[CmdletBinding()]
param(
  [string]$Site,
  [int]$Port = 8801
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Site) { $Site = Join-Path $root 'docs/_site' }
$Site = (Resolve-Path -LiteralPath $Site).Path

$installer = Join-Path $root 'docs/install.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
$profilePath = Join-Path $scratch 'Profile/profile.ps1'
$completionPath = Join-Path $scratch 'Profile/Completions/quarto.ps1'

$script:Passed = 0
$script:Failed = 0

function Write-Report {
  param([string]$Message = '')
  Write-Information -MessageData $Message -InformationAction Continue
}

function Test-Pass {
  param([string]$Label)
  Write-Report "ok    $Label"
  $script:Passed++
}

function Test-Fail {
  param([string]$Label, [string]$Detail)
  Write-Report "FAIL  $Label"
  Write-Report "      $Detail"
  $script:Failed++
}

function Assert-FilePresent {
  param([string]$Label, [string]$Path)
  if (Test-Path -LiteralPath $Path) { Test-Pass $Label }
  else { Test-Fail $Label "missing file: $Path" }
}

function Assert-FileMissing {
  param([string]$Label, [string]$Path)
  if (Test-Path -LiteralPath $Path) { Test-Fail $Label "expected to be gone: $Path" }
  else { Test-Pass $Label }
}

function Assert-Count {
  param([string]$Label, [string]$Path, [string]$Needle, [int]$Expected)
  $actual = 0
  if (Test-Path -LiteralPath $Path) {
    $actual = @(Get-Content -LiteralPath $Path | Where-Object { $_ -like "*$Needle*" }).Count
  }
  if ($actual -eq $Expected) { Test-Pass $Label }
  else { Test-Fail $Label "expected $Expected occurrences of '$Needle', found $actual" }
}

function Invoke-Installer {
  param([string]$BaseUrl, [string[]]$Arguments = @())

  $env:QUARTO_COMPLETIONS_PROFILE = $profilePath
  & pwsh -NoProfile -File $installer -BaseUrl $BaseUrl @Arguments 2>&1 | Out-String
}

function Get-Python {
  # Windows runners ship `python`; Linux and macOS ship `python3`.
  foreach ($name in @('python3', 'python')) {
    if (Get-Command $name -ErrorAction SilentlyContinue) { return $name }
  }
  throw 'no python interpreter on PATH to serve the site with'
}

function Start-Site {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$Directory, [int]$On)

  if (-not $PSCmdlet.ShouldProcess("port $On", 'Serve the site')) { return }

  # -WindowStyle is Windows-only, so the server's own logging is redirected
  # instead of hidden, which keeps it out of the test output everywhere.
  $log = Join-Path $scratch "server-$On"
  $server = Start-Process -PassThru -NoNewWindow `
    -FilePath (Get-Python) -ArgumentList @('-m', 'http.server', "$On", '--directory', $Directory) `
    -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
  foreach ($attempt in 1..60) {
    try {
      Invoke-RestMethod -Uri "http://127.0.0.1:$On/completions/stable/manifest.json" -UseBasicParsing | Out-Null
      return $server
    }
    catch {
      Start-Sleep -Seconds 1
    }
  }
  throw "the local server never answered on port $On"
}

if (-not (Test-Path -LiteralPath $Site)) {
  throw "no rendered site at $Site (run: quarto render docs)"
}

New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$server = Start-Site -Directory $Site -On $Port
$baseUrl = "http://127.0.0.1:$Port"

try {
  Invoke-Installer -BaseUrl $baseUrl -Arguments @('-DryRun') | Out-Null
  Assert-FileMissing 'dry run writes nothing' $completionPath
  Assert-FileMissing 'dry run leaves the profile alone' $profilePath

  $output = Invoke-Installer -BaseUrl $baseUrl
  if ($LASTEXITCODE -eq 0) { Test-Pass 'install succeeds' }
  else { Test-Fail 'install succeeds' $output }

  Assert-FilePresent 'script installed' $completionPath
  Assert-FilePresent 'profile written' $profilePath
  # -like is case-insensitive, so a needle of 'Completions' would also count
  # the two managed-block markers.
  Assert-Count 'profile dot-sources the script' $profilePath 'quarto.ps1' 1

  # The completer the installer just wrote has to load and answer. The line and
  # its length are interpolated here, so the inner session needs no escaping.
  $line = 'quarto render --to '
  $completions = & pwsh -NoProfile -Command "
    . '$completionPath'
    (TabExpansion2 '$line' $($line.Length)).CompletionMatches.CompletionText -join ' '
  " | Out-String
  if ($completions -match 'revealjs') { Test-Pass 'installed script completes formats' }
  else { Test-Fail 'installed script completes formats' $completions }

  Invoke-Installer -BaseUrl $baseUrl | Out-Null
  Assert-Count 'managed block is not duplicated' $profilePath '>>> quarto completions >>>' 1

  # A download that no longer matches the manifest is refused.
  $tampered = Join-Path $scratch 'tampered'
  Copy-Item -Recurse -LiteralPath $Site -Destination $tampered
  Add-Content -LiteralPath (Join-Path $tampered 'completions/stable/quarto.ps1') -Value '# tampered'
  $tamperedServer = Start-Site -Directory $tampered -On ($Port + 1)
  try {
    $output = Invoke-Installer -BaseUrl "http://127.0.0.1:$($Port + 1)"
    if ($LASTEXITCODE -ne 0 -and $output -match 'Checksum mismatch') {
      Test-Pass 'a checksum mismatch is refused'
    }
    else {
      Test-Fail 'a checksum mismatch is refused' $output
    }
  }
  finally {
    Stop-Process -Id $tamperedServer.Id -ErrorAction SilentlyContinue
  }

  Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Uninstall') | Out-Null
  Assert-FileMissing 'script removed' $completionPath
  Assert-Count 'managed block removed' $profilePath '>>> quarto completions >>>' 0
}
finally {
  Stop-Process -Id $server.Id -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue
  Remove-Item Env:\QUARTO_COMPLETIONS_PROFILE -ErrorAction SilentlyContinue
}

Write-Report
Write-Report "$script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
