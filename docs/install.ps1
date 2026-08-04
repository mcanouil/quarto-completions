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
  and QUARTO_COMPLETIONS_UNINSTALL=1. QUARTO_COMPLETIONS_PROFILE overrides the
  profile that is written to, which is how the tests avoid touching a real one.

  Runs on Windows PowerShell 5.1, which is what `powershell.exe` is, as well as
  PowerShell 7.
#>

[CmdletBinding()]
param(
  # No ValidateSet: Windows PowerShell 5.1 would skip it for the default value
  # read from the environment, and PowerShell 7 would refuse that value with
  # its own wording. The one check below covers both paths with one message.
  [string]$Channel = $(if ($env:QUARTO_COMPLETIONS_CHANNEL) { $env:QUARTO_COMPLETIONS_CHANNEL } else { 'stable' }),

  [string]$BaseUrl = $(if ($env:QUARTO_COMPLETIONS_BASE_URL) { $env:QUARTO_COMPLETIONS_BASE_URL } else { 'https://m.canouil.dev/quarto-completions' }),

  [switch]$Uninstall,

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not negotiate TLS 1.2 by default on older builds,
# where every download would otherwise fail with a connection error.
if ([Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Promoted to script scope so the functions below read one binding rather than
# closing over the parameters.
$script:Channel = $Channel
if ($script:Channel -notin @('stable', 'prerelease')) {
  throw "Channel must be 'stable' or 'prerelease', got '$($script:Channel)'"
}
$script:BaseUrl = $BaseUrl.TrimEnd('/')
$script:DryRun = [bool]$DryRun
$script:Uninstall = [bool]$Uninstall -or ($env:QUARTO_COMPLETIONS_UNINSTALL -eq '1')

$script:BlockStart = '# >>> quarto completions >>>'
$script:BlockEnd = '# <<< quarto completions <<<'
$script:ProfilePath = if ($env:QUARTO_COMPLETIONS_PROFILE) {
  $env:QUARTO_COMPLETIONS_PROFILE
}
else {
  $PROFILE.CurrentUserAllHosts
}
# Nested rather than the three-argument form, which Windows PowerShell 5.1 does
# not have, and one segment at a time: a '/' inside a single argument survives
# into the result, which is then printed and dot-sourced with mixed separators.
$script:CompletionPath =
  Join-Path (Join-Path (Split-Path -Parent $script:ProfilePath) 'Completions') 'quarto.ps1'

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

  # -UseBasicParsing keeps 5.1 from waiting on Internet Explorer's engine.
  $manifest = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing
  $expected = $manifest.files.'quarto.ps1'
  if (-not $expected) {
    throw "No checksum for quarto.ps1 in $manifestUrl"
  }

  $temporary = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
  try {
    Invoke-WebRequest -Uri $url -OutFile $temporary -UseBasicParsing

    $actual = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected.ToLowerInvariant()) {
      throw "Checksum mismatch for quarto.ps1: expected $expected, got $actual"
    }

    $directory = Split-Path -Parent $script:CompletionPath
    if (-not (Test-Path -LiteralPath $directory)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    Move-Item -LiteralPath $temporary -Destination $script:CompletionPath -Force
  }
  finally {
    # Gone already when the move above succeeded; left behind by a failed
    # download or a mismatch, which is what this sweeps up.
    if (Test-Path -LiteralPath $temporary) {
      Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
  }
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
