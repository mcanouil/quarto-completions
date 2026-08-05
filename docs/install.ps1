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
  # Left empty rather than defaulted to 'stable' here: the block below tells
  # an unset channel from an explicit one, which is what lets it pick 'dev'
  # only when nothing named a channel at all.
  [string]$Channel = $(if ($env:QUARTO_COMPLETIONS_CHANNEL) { $env:QUARTO_COMPLETIONS_CHANNEL } else { '' }),

  [string]$BaseUrl = $(if ($env:QUARTO_COMPLETIONS_BASE_URL) { $env:QUARTO_COMPLETIONS_BASE_URL } else { 'https://m.canouil.dev/quarto-completions' }),

  [switch]$Uninstall,

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 on an older build pins SecurityProtocol to an explicit
# legacy set, Ssl3 and Tls, where every download fails with a connection error.
# Adding Tls12 to that set is the fix.
#
# SystemDefault is left exactly as it is, which is what every current build
# reports and what this used to overwrite: it means "let the platform
# negotiate", already covers TLS 1.2, and is the only value that can reach TLS
# 1.3, so replacing it with an explicit Tls12 opted out of the newer protocol
# rather than enabling anything.
if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault -and
  [Net.ServicePointManager]::SecurityProtocol -notmatch 'Tls12') {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Promoted to script scope so the functions below read one binding rather than
# closing over the parameters. Computed before the channel below, which reads
# it to skip a probe that channel-less uninstall never needs.
$script:Uninstall = [bool]$Uninstall -or ($env:QUARTO_COMPLETIONS_UNINSTALL -eq '1')

$script:Channel = $Channel
# The quarto on PATH's reported version, or empty when there is none or it
# does not answer. Read once, ahead of channel resolution, and shared by the
# dev auto-detect below and the version advisory in Install-QuartoCompletion,
# so an install spawns quarto at most once. Uninstalling never reads it.
$script:LocalQuartoVersion = ''
if (-not $script:Uninstall) {
  # -CommandType Application: a function or alias named 'quarto' has no
  # '.Source' to invoke, and a PATH with more than one binary would otherwise
  # hand back an array that '&' cannot call. -First 1 takes the one PATH
  # itself would run.
  $quartoOnPath = Get-Command quarto -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($quartoOnPath) {
    try {
      $script:LocalQuartoVersion = (& $quartoOnPath.Source --version 2>$null | Select-Object -First 1).ToString().Trim()
    }
    catch {
      $script:LocalQuartoVersion = ''
    }
  }
}
if (-not $script:Channel -and $script:Uninstall) {
  # Uninstalling never reads $script:Channel, so an unset one here is left at
  # a placeholder rather than spent starting quarto for nothing.
  $script:Channel = 'stable'
}
if (-not $script:Channel) {
  # Only a quarto on PATH reporting exactly '99.9.9' selects 'dev': that is
  # the version Quarto's own kLocalDevelopment constant reports for an
  # unreleased source build, the one build whose hidden commands the dev
  # channel completes.
  $script:Channel = if ($script:LocalQuartoVersion -eq '99.9.9') { 'dev' } else { 'stable' }
}
if ($script:Channel -notin @('stable', 'prerelease', 'dev')) {
  throw "Channel must be 'stable', 'prerelease', or 'dev', got '$($script:Channel)'"
}
$script:BaseUrl = $BaseUrl.TrimEnd('/')
$script:DryRun = [bool]$DryRun

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
  $found = $false
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ($line -eq $script:BlockStart) { $inside = $true; $found = $true; continue }
    if ($line -eq $script:BlockEnd) { $inside = $false; continue }
    if (-not $inside) { $kept += $line }
  }
  # Still inside at the end means the block never closed, so everything below
  # the opening marker has just been dropped from $kept. That is the user's
  # own content, not this installer's, so the file is left exactly as it is.
  if ($inside) {
    throw "The quarto completions block in $Path has no closing '$($script:BlockEnd)' line; repair or remove the block, then re-run"
  }
  # A profile carrying no block is not this installer's to rewrite: writing it
  # back would normalise its line endings and re-encode it, adding a BOM on
  # Windows PowerShell 5.1, for a file there is nothing to remove from. The
  # POSIX installer guards the same way, with rc_block_present.
  if (-not $found) { return }
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

function Script:Get-VersionMajorMinor {
  param([string]$Version)

  if ($Version -match '^(\d+)\.(\d+)') {
    return "$($Matches[1]).$($Matches[2])"
  }
  return ''
}

# Writes the one advisory line for a Quarto that does not match what these
# completions were generated from, or nothing when there is nothing useful to
# say. Never fails the install; a mismatch is only ever a note.
function Script:Write-VersionAdvice {
  param([string]$ManifestVersion, [string]$LocalVersion, [string]$Channel)

  if (-not $LocalVersion -or $LocalVersion -eq '99.9.9' -or $Channel -eq 'dev') { return }

  $manifestMM = Script:Get-VersionMajorMinor $ManifestVersion
  $localMM = Script:Get-VersionMajorMinor $LocalVersion
  if (-not $manifestMM -or -not $localMM -or $manifestMM -eq $localMM) { return }

  $manifestParts = $manifestMM -split '\.'
  $localParts = $localMM -split '\.'
  $newer = ([int]$localParts[0] -gt [int]$manifestParts[0]) -or
    ([int]$localParts[0] -eq [int]$manifestParts[0] -and [int]$localParts[1] -gt [int]$manifestParts[1])

  if ($newer) {
    if ($Channel -eq 'stable') {
      Script:Write-Log "Your Quarto is $LocalVersion, newer than these completions. Run again with -Channel prerelease if you are on a Quarto prerelease."
    }
    else {
      Script:Write-Log "Your Quarto is $LocalVersion, newer than these completions; flags added since then are not completed yet."
    }
  }
  else {
    Script:Write-Log "Your Quarto is $LocalVersion, older than these completions; some completions may name flags your Quarto does not have."
  }
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
  Script:Write-VersionAdvice -ManifestVersion $manifest.quartoVersion -LocalVersion $script:LocalQuartoVersion -Channel $script:Channel
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
