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

# Promoted to script scope so the functions below read one binding rather than
# closing over the parameters.
$script:Channel = $Channel
$script:BaseUrl = $BaseUrl.TrimEnd('/')
$script:DryRun = [bool]$DryRun
$script:Uninstall = [bool]$Uninstall -or ($env:QUARTO_COMPLETIONS_UNINSTALL -eq '1')

$script:BlockStart = '# >>> quarto completions >>>'
$script:BlockEnd = '# <<< quarto completions <<<'
$script:ProfilePath = $PROFILE.CurrentUserAllHosts
$script:CompletionPath = Join-Path (Split-Path -Parent $script:ProfilePath) 'Completions/quarto.ps1'

function Script:Write-Log {
  param([string]$Message = '')

  Write-Information -MessageData $Message -InformationAction Continue
}

function Script:Remove-ManagedBlock {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (-not $PSCmdlet.ShouldProcess($Path, 'Remove the managed block')) { return }

  $kept = @()
  $inside = $false
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ($line -eq $script:BlockStart) { $inside = $true; continue }
    if ($line -eq $script:BlockEnd) { $inside = $false; continue }
    if (-not $inside) { $kept += $line }
  }
  Set-Content -LiteralPath $Path -Value $kept -Encoding utf8
}

function Script:Set-ManagedBlock {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Body)

  if (-not $PSCmdlet.ShouldProcess($Path, 'Write the managed block')) { return }

  Script:Remove-ManagedBlock -Path $Path
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  Add-Content -LiteralPath $Path -Value @($script:BlockStart, $Body, $script:BlockEnd) -Encoding utf8
}

function Script:Install-QuartoCompletion {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  $url = "$($script:BaseUrl)/completions/$($script:Channel)/quarto.ps1"
  $manifestUrl = "$($script:BaseUrl)/completions/$($script:Channel)/manifest.json"

  if ($script:DryRun) {
    Script:Write-Log "Would download $url"
    Script:Write-Log "Would write    $($script:CompletionPath)"
    Script:Write-Log "Would update   $($script:ProfilePath) (managed block)"
    return
  }

  if (-not $PSCmdlet.ShouldProcess($script:CompletionPath, 'Install Quarto completions')) { return }

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

  $directory = Split-Path -Parent $script:CompletionPath
  if (-not (Test-Path -LiteralPath $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  Move-Item -LiteralPath $temporary -Destination $script:CompletionPath -Force
  Script:Write-Log "Installed $($script:CompletionPath)"

  Script:Set-ManagedBlock -Path $script:ProfilePath -Body ". `"$($script:CompletionPath)`""
  Script:Write-Log "Updated $($script:ProfilePath)"

  Script:Write-Log
  Script:Write-Log "Quarto $($manifest.quartoVersion) completions for PowerShell ($($script:Channel) channel)."
  Script:Write-Log "Start a new session, or run: . `"$($script:CompletionPath)`""
}

function Script:Uninstall-QuartoCompletion {
  [CmdletBinding(SupportsShouldProcess)]
  param()

  if ($script:DryRun) {
    Script:Write-Log "Would remove $($script:CompletionPath)"
    Script:Write-Log "Would clean  $($script:ProfilePath) (managed block)"
    return
  }

  if (-not $PSCmdlet.ShouldProcess($script:CompletionPath, 'Remove Quarto completions')) { return }

  if (Test-Path -LiteralPath $script:CompletionPath) {
    Remove-Item -LiteralPath $script:CompletionPath -Force
    Script:Write-Log "Removed $($script:CompletionPath)"
  }
  else {
    Script:Write-Log "Nothing to remove at $($script:CompletionPath)"
  }

  Script:Remove-ManagedBlock -Path $script:ProfilePath
  Script:Write-Log "Cleaned $($script:ProfilePath)"
}

if ($script:Uninstall) {
  Script:Uninstall-QuartoCompletion
}
else {
  Script:Install-QuartoCompletion
}
