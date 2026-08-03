<#
.SYNOPSIS
  Installs Quarto CLI shell completions for PowerShell.

.DESCRIPTION
  Downloads the generated completion script, verifies its SHA-256 against the
  published manifest, writes it under the current user's profile directory, and
  dot-sources it from the profile inside a managed block that re-running
  replaces rather than duplicates.

  Everything is written under the user's profile. Nothing needs elevation.

.EXAMPLE
  powershell -ExecutionPolicy ByPass -c "irm https://m.canouil.dev/quarto-completions/install.ps1 | iex"

.NOTES
  The piped form above cannot take parameters, so each one also reads an
  environment variable: QUARTO_COMPLETIONS_CHANNEL, QUARTO_COMPLETIONS_BASE_URL,
  and QUARTO_COMPLETIONS_UNINSTALL=1.
#>

[CmdletBinding()]
param(
  [ValidateSet('stable', 'prerelease')]
  [string]$Channel = $(if ($env:QUARTO_COMPLETIONS_CHANNEL) { $env:QUARTO_COMPLETIONS_CHANNEL } else { 'stable' }),

  [string]$BaseUrl = $(if ($env:QUARTO_COMPLETIONS_BASE_URL) { $env:QUARTO_COMPLETIONS_BASE_URL } else { 'https://m.canouil.dev/quarto-completions' }),

  [switch]$Uninstall,

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$BlockStart = '# >>> quarto completions >>>'
$BlockEnd = '# <<< quarto completions <<<'

if ($env:QUARTO_COMPLETIONS_UNINSTALL -eq '1') { $Uninstall = $true }

$profilePath = $PROFILE.CurrentUserAllHosts
$completionPath = Join-Path (Split-Path -Parent $profilePath) 'Completions/quarto.ps1'

function Remove-ManagedBlock {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return }

  $lines = Get-Content -LiteralPath $Path
  $kept = @()
  $inside = $false
  foreach ($line in $lines) {
    if ($line -eq $BlockStart) { $inside = $true; continue }
    if ($line -eq $BlockEnd) { $inside = $false; continue }
    if (-not $inside) { $kept += $line }
  }
  Set-Content -LiteralPath $Path -Value $kept -Encoding utf8
}

function Write-ManagedBlock {
  param([string]$Path, [string]$Body)

  Remove-ManagedBlock -Path $Path
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  Add-Content -LiteralPath $Path -Value @($BlockStart, $Body, $BlockEnd) -Encoding utf8
}

function Install-Completions {
  $url = "$BaseUrl/completions/$Channel/quarto.ps1"
  $manifestUrl = "$BaseUrl/completions/$Channel/manifest.json"

  if ($DryRun) {
    Write-Host "Would download $url"
    Write-Host "Would write    $completionPath"
    Write-Host "Would update   $profilePath (managed block)"
    return
  }

  $manifest = Invoke-RestMethod -Uri $manifestUrl
  $expected = $manifest.files.'quarto.ps1'
  if (-not $expected) {
    throw "No checksum for quarto.ps1 in $manifestUrl"
  }

  $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
  Invoke-WebRequest -Uri $url -OutFile $temporary

  $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $expected.ToLowerInvariant()) {
    Remove-Item -LiteralPath $temporary -Force
    throw "Checksum mismatch for quarto.ps1: expected $expected, got $actual"
  }

  $directory = Split-Path -Parent $completionPath
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  Move-Item -LiteralPath $temporary -Destination $completionPath -Force
  Write-Host "Installed $completionPath"

  Write-ManagedBlock -Path $profilePath -Body ". `"$completionPath`""
  Write-Host "Updated $profilePath"

  Write-Host ''
  Write-Host "Quarto $($manifest.quartoVersion) completions for PowerShell ($Channel channel)."
  Write-Host "Start a new session, or run: . `"$completionPath`""
}

function Uninstall-Completions {
  if ($DryRun) {
    Write-Host "Would remove $completionPath"
    Write-Host "Would clean  $profilePath (managed block)"
    return
  }

  if (Test-Path -LiteralPath $completionPath) {
    Remove-Item -LiteralPath $completionPath -Force
    Write-Host "Removed $completionPath"
  }
  else {
    Write-Host "Nothing to remove at $completionPath"
  }

  Remove-ManagedBlock -Path $profilePath
  Write-Host "Cleaned $profilePath"
}

if ($Uninstall) { Uninstall-Completions } else { Install-Completions }
