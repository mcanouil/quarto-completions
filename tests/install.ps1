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

# Unlike -Channel, there is no flag that can override this once the installer
# reads it as '1': a developer with it exported would otherwise have it
# inherited by every child pwsh Invoke-Installer starts below, silently
# turning every "install succeeds" scenario into an uninstall. Cleared once,
# here, rather than per call: nothing in this script sets it again.
Remove-Item Env:\QUARTO_COMPLETIONS_UNINSTALL -ErrorAction SilentlyContinue

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $Site) { $Site = Join-Path $root 'docs/_site' }
$Site = (Resolve-Path -LiteralPath $Site).Path

$installer = Join-Path $root 'docs/install.ps1'
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
# Built one segment at a time, the way the installer builds it, so the test
# asserts on the string the installer would produce and not on a variant the
# file system happens to accept as well.
$profileDirectory = Join-Path $scratch 'Profile'
$profilePath = Join-Path $profileDirectory 'profile.ps1'
$completionPath = Join-Path (Join-Path $profileDirectory 'Completions') 'quarto.ps1'

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
  param([string]$BaseUrl, [string[]]$Arguments = @(), [switch]$SkipChannelPin)

  $env:QUARTO_COMPLETIONS_PROFILE = $profilePath
  # Pinned to 'stable' unconditionally, matching tests/install.sh's pin for
  # bash, unless the caller already named a channel on the command line, or
  # passes -SkipChannelPin because it is itself exercising
  # QUARTO_COMPLETIONS_CHANNEL and needs the ambient environment to reach the
  # installer untouched: PowerShell errors on a duplicate -Channel, so this
  # must not add one on top of that test's own. Everywhere else, this keeps
  # the suite from depending on whatever channel a developer's shell happens
  # to have exported, or on whatever quarto happens to be on PATH.
  if (-not $SkipChannelPin -and $Arguments -notcontains '-Channel') {
    $Arguments = @('-Channel', 'stable') + $Arguments
  }
  & pwsh -NoProfile -File $installer -BaseUrl $BaseUrl @Arguments 2>&1 | Out-String
}

# Writes a fake `quarto` to $Directory that ignores its arguments and always
# reports $Version, the way the bash suite's shim does. A .cmd on Windows,
# since Get-Command -CommandType Application only finds files PATHEXT names;
# an extension-less script works everywhere else. -Encoding ascii avoids a BOM
# that would otherwise corrupt the first line either shell reads.
function Write-QuartoShimVersion {
  param([string]$Directory, [string]$Version)

  if ($IsWindows) {
    Set-Content -LiteralPath (Join-Path $Directory 'quarto.cmd') -Value "@echo $Version" -Encoding ascii
  }
  else {
    $path = Join-Path $Directory 'quarto'
    Set-Content -LiteralPath $path -Value @('#!/usr/bin/env sh', "printf '%s\n' '$Version'") -Encoding ascii
    & chmod +x $path
  }
}

# Runs the installer with PATH pointed at $QuartoPath ahead of whatever real
# quarto the runner already has (test.yml installs one for the rest of the
# suite), or with that real one stripped out entirely when $QuartoPath is
# empty, standing in for a machine with none.
function Invoke-InstallerWithQuarto {
  param([string]$BaseUrl, [string]$QuartoPath, [string[]]$Arguments = @())

  $separator = [System.IO.Path]::PathSeparator
  $original = $env:PATH
  try {
    if ($QuartoPath) {
      $env:PATH = "$QuartoPath$separator$original"
    }
    else {
      $real = Get-Command quarto -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($real) {
        $realDirectory = Split-Path -Parent $real.Source
        $env:PATH = (($original -split [regex]::Escape($separator)) |
            Where-Object { $_ -ne $realDirectory }) -join $separator
      }
    }
    Invoke-Installer -BaseUrl $BaseUrl -Arguments $Arguments
  }
  finally {
    $env:PATH = $original
  }
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

  # ValidateSet does not run on default values, so a channel arriving through
  # the environment has to be refused by the installer itself.
  $env:QUARTO_COMPLETIONS_CHANNEL = 'nonsense'
  try {
    $output = Invoke-Installer -BaseUrl $baseUrl -SkipChannelPin
    if ($LASTEXITCODE -ne 0 -and $output -match "'stable', 'prerelease', or 'dev'") {
      Test-Pass 'an unknown channel from the environment is refused'
    }
    else {
      Test-Fail 'an unknown channel from the environment is refused' $output
    }
  }
  finally {
    Remove-Item Env:\QUARTO_COMPLETIONS_CHANNEL -ErrorAction SilentlyContinue
  }

  # A download that no longer matches the manifest is refused.
  $tampered = Join-Path $scratch 'tampered'
  Copy-Item -Recurse -LiteralPath $Site -Destination $tampered
  Add-Content -LiteralPath (Join-Path $tampered 'completions/stable/quarto.ps1') -Value '# tampered'
  $tamperedServer = Start-Site -Directory $tampered -On ($Port + 1)
  try {
    # -Channel stable is explicit here: this asserts on the file tampered
    # above, and the default channel would otherwise follow whatever quarto
    # happens to be on the machine running the suite.
    $output = Invoke-Installer -BaseUrl "http://127.0.0.1:$($Port + 1)" -Arguments @('-Channel', 'stable')
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

  # -Channel dev fetches from the dev channel published alongside stable and
  # prerelease: generated from a 99.9.9 quarto-cli source build, and the only
  # one that carries the hidden commands (dev-call and the rest). The channel
  # only changes which URL is fetched, not where the script is installed, so
  # this lands at the same $completionPath as every install above.
  $output = Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', 'dev')
  if ($LASTEXITCODE -eq 0) { Test-Pass 'a dev channel install succeeds' }
  else { Test-Fail 'a dev channel install succeeds' $output }
  Assert-FilePresent 'dev channel: script installed' $completionPath
  Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', 'dev', '-Uninstall') | Out-Null

  # The version advisory compares the manifest's Quarto version against
  # whatever quarto reports on PATH. Mirrors the shim-based cases in
  # tests/install.sh; the older-version and patch-only-difference cases are
  # covered there and not repeated here.
  $quartoShimDirectory = Join-Path $scratch 'quarto-shim'
  New-Item -ItemType Directory -Path $quartoShimDirectory -Force | Out-Null

  $stableManifest = Get-Content -Raw (Join-Path $Site 'completions/stable/manifest.json') | ConvertFrom-Json
  $stableParts = $stableManifest.quartoVersion -split '\.'
  $stableMajor = [int]$stableParts[0]
  $stableMinor = [int]$stableParts[1]

  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version "$stableMajor.$stableMinor.0"
  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @('-Channel', 'stable')
  if ($output -notmatch 'than these completions') { Test-Pass 'advisory: a matching major.minor says nothing' }
  else { Test-Fail 'advisory: a matching major.minor says nothing' $output }

  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version "$stableMajor.$($stableMinor + 1).0"
  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @('-Channel', 'stable')
  if ($output -match [regex]::Escape('-Channel prerelease')) { Test-Pass 'advisory: a newer Quarto names -Channel prerelease' }
  else { Test-Fail 'advisory: a newer Quarto names -Channel prerelease' $output }

  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version '99.9.9'
  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @('-Channel', 'stable')
  if ($output -notmatch 'than these completions') { Test-Pass 'advisory: the dev sentinel says nothing' }
  else { Test-Fail 'advisory: the dev sentinel says nothing' $output }

  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath '' -Arguments @('-Channel', 'stable')
  if ($output -notmatch 'than these completions') { Test-Pass 'advisory: no quarto on PATH says nothing' }
  else { Test-Fail 'advisory: no quarto on PATH says nothing' $output }

  Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Uninstall') | Out-Null
}
finally {
  Stop-Process -Id $server.Id -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue
  Remove-Item Env:\QUARTO_COMPLETIONS_PROFILE -ErrorAction SilentlyContinue
}

Write-Report
Write-Report "$script:Passed passed, $script:Failed failed."
if ($script:Failed -gt 0) { exit 1 }
