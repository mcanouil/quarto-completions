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

# One line, with the colouring stripped, for an assertion on an error message
# rather than on a log line.
#
# PowerShell's error view wraps a long message across several lines, each
# continuation prefixed with '|', and where it wraps depends on the width of
# the console and on the length of the paths in the message. A phrase from the
# middle of a message is therefore not a contiguous string in the raw output:
# on a Windows runner, whose temporary paths are long, 'no closing' arrived
# split across two lines.
function Get-FlatOutput {
  param([string]$Output)

  $plain = $Output -replace "$([char]27)\[[0-9;]*m", ''
  ($plain -replace '(\r?\n)\s*\|\s*', ' ') -replace '\s+', ' '
}

function Invoke-Installer {
  param([string]$BaseUrl, [string[]]$Arguments = @(), [switch]$SkipChannelPin)

  $env:QUARTO_COMPLETIONS_PROFILE = $profilePath
  # Pinned to 'release' unconditionally, matching tests/install.sh's pin for
  # bash, unless the caller already named a channel on the command line, or
  # passes -SkipChannelPin because it is itself exercising
  # QUARTO_COMPLETIONS_CHANNEL and needs the ambient environment to reach the
  # installer untouched: PowerShell errors on a duplicate -Channel, so this
  # must not add one on top of that test's own. Everywhere else, this keeps
  # the suite from depending on whatever channel a developer's shell happens
  # to have exported, or on whatever quarto happens to be on PATH.
  if (-not $SkipChannelPin -and $Arguments -notcontains '-Channel') {
    $Arguments = @('-Channel', 'release') + $Arguments
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
  param([string]$BaseUrl, [string]$QuartoPath, [string[]]$Arguments = @(), [switch]$SkipChannelPin)

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
    Invoke-Installer -BaseUrl $BaseUrl -Arguments $Arguments -SkipChannelPin:$SkipChannelPin
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
      Invoke-RestMethod -Uri "http://127.0.0.1:$On/completions/release/manifest.json" -UseBasicParsing | Out-Null
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
    if ($LASTEXITCODE -ne 0 -and $output -match "'release', 'pre-release', 'dev'") {
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
  Add-Content -LiteralPath (Join-Path $tampered 'completions/release/quarto.ps1') -Value '# tampered'
  $tamperedServer = Start-Site -Directory $tampered -On ($Port + 1)
  try {
    # -Channel release is explicit here: this asserts on the file tampered
    # above, and the default channel would otherwise follow whatever quarto
    # happens to be on the machine running the suite.
    $output = Invoke-Installer -BaseUrl "http://127.0.0.1:$($Port + 1)" -Arguments @('-Channel', 'release')
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

  # Where PowerShell breaks a message is not reproducible on demand: it follows
  # the console width and the length of the paths in the message. Pinned here
  # against the shape a Windows runner produced, so the normalisation the four
  # assertions below rely on is itself covered wherever the suite runs.
  $wrapped = @(
    '     | The quarto completions block in C:\Temp\Profile\profile.ps1 has no',
    "     | closing '# <<< quarto completions <<<' line. Repair or remove the block, then re-run"
  ) -join "`r`n"
  if ((Get-FlatOutput $wrapped) -match 'no closing') {
    Test-Pass 'a wrapped error message reads as one line'
  }
  else {
    Test-Fail 'a wrapped error message reads as one line' (Get-FlatOutput $wrapped)
  }

  # A block whose closing marker is gone, which is what a hand edit, a merge
  # conflict, or a half-written file leaves behind. The scan that drops the
  # block never leaves the block on such a file, so everything below the
  # opening marker went with it. Both paths must stop and leave the file as
  # it is. Mirrors the same scenario in tests/install.sh.
  function Write-UnterminatedProfile {
    Set-Content -LiteralPath $profilePath -Encoding utf8 -Value @(
      '# >>> quarto completions >>>',
      '. "$HOME/Completions/quarto.ps1"',
      '$Sentinel = "keep-me"'
    )
  }

  Write-UnterminatedProfile
  $output = Get-FlatOutput (Invoke-Installer -BaseUrl $baseUrl)
  if ($LASTEXITCODE -ne 0 -and $output -match 'no closing') {
    Test-Pass 'an unterminated block fails the install'
  }
  else {
    Test-Fail 'an unterminated block fails the install' $output
  }
  Assert-Count 'install left the content below the block alone' $profilePath 'keep-me' 1

  Write-UnterminatedProfile
  $output = Get-FlatOutput (Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Uninstall'))
  if ($LASTEXITCODE -ne 0 -and $output -match 'no closing') {
    Test-Pass 'an unterminated block fails the uninstall'
  }
  else {
    Test-Fail 'an unterminated block fails the uninstall' $output
  }
  Assert-Count 'uninstall left the content below the block alone' $profilePath 'keep-me' 1

  # -DryRun printed its lines unconditionally, so it promised an update and a
  # clean the runs above refuse. It has to report the problem instead, and end
  # the way they do. Mirrors the same scenario in tests/install.sh.
  Write-UnterminatedProfile
  $output = Get-FlatOutput (Invoke-Installer -BaseUrl $baseUrl -Arguments @('-DryRun'))
  if ($LASTEXITCODE -ne 0 -and $output -match 'no closing' -and $output -notmatch 'Would update') {
    Test-Pass 'an unterminated block fails a dry-run install'
  }
  else {
    Test-Fail 'an unterminated block fails a dry-run install' $output
  }
  Assert-Count 'the dry-run install left the content below the block alone' $profilePath 'keep-me' 1

  Write-UnterminatedProfile
  $output = Get-FlatOutput (Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Uninstall', '-DryRun'))
  if ($LASTEXITCODE -ne 0 -and $output -match 'no closing' -and $output -notmatch 'Would clean') {
    Test-Pass 'an unterminated block fails a dry-run uninstall'
  }
  else {
    Test-Fail 'an unterminated block fails a dry-run uninstall' $output
  }
  Assert-Count 'the dry-run uninstall left the content below the block alone' $profilePath 'keep-me' 1

  # Left as the installer's own uninstall would leave it, so the scenarios
  # below start from a profile with no block rather than this crafted one.
  Set-Content -LiteralPath $profilePath -Value @() -Encoding utf8

  # A profile that carries no block at all is not this installer's to rewrite.
  # Reading it in and writing it back normalises its line endings and re-encodes
  # it, which on Windows PowerShell 5.1 adds a BOM, for a file the run has
  # nothing to change in. Compared byte for byte, since every difference here is
  # one the content alone would not show.
  $untouchedProfile = Join-Path $scratch 'untouched-profile.ps1'
  [System.IO.File]::WriteAllText(
    $untouchedProfile,
    "# my own profile`r`nSet-Alias ll Get-ChildItem`r`n"
  )
  $before = (Get-FileHash -LiteralPath $untouchedProfile -Algorithm SHA256).Hash
  $env:QUARTO_COMPLETIONS_PROFILE = $untouchedProfile
  try {
    & pwsh -NoProfile -File $installer -BaseUrl $baseUrl -Channel release -Uninstall 2>&1 | Out-String | Out-Null
  }
  finally {
    $env:QUARTO_COMPLETIONS_PROFILE = $profilePath
  }
  $after = (Get-FileHash -LiteralPath $untouchedProfile -Algorithm SHA256).Hash
  if ($before -eq $after) { Test-Pass 'a profile with no block is left byte for byte alone' }
  else { Test-Fail 'a profile with no block is left byte for byte alone' 'the profile was rewritten' }

  # -Channel dev fetches from the dev channel published alongside release and
  # pre-release: generated from a 99.9.9 quarto-cli source build, and the only
  # one that carries the hidden commands (dev-call and the rest). The channel
  # only changes which URL is fetched, not where the script is installed, so
  # this lands at the same $completionPath as every install above.
  $output = Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', 'dev')
  if ($LASTEXITCODE -eq 0) { Test-Pass 'a dev channel install succeeds' }
  else { Test-Fail 'a dev channel install succeeds' $output }
  Assert-FilePresent 'dev channel: script installed' $completionPath
  Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', 'dev', '-Uninstall') | Out-Null

  # -Channel 1.9 fetches a minor of its own, published alongside release,
  # pre-release, and dev: one line, named, where the two aliases roll.
  $output = Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', '1.9')
  if ($LASTEXITCODE -eq 0) { Test-Pass 'a version channel install succeeds' }
  else { Test-Fail 'a version channel install succeeds' $output }
  Assert-FilePresent 'version channel: script installed' $completionPath
  Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', '1.9', '-Uninstall') | Out-Null

  # A channel naming anything but a bare major.minor is refused the same way
  # an unrecognised word is.
  $output = Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', '1.9.3')
  if ($LASTEXITCODE -ne 0) { Test-Pass 'a three-part version channel is refused' }
  else { Test-Fail 'a three-part version channel is refused' $output }

  # A channel that is a bare major.minor but has nothing published is named in
  # the error rather than left to the raw web exception. 1.5 is older than
  # every published minor, so the site served here has no directory for it.
  $output = Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', '1.5')
  if ($LASTEXITCODE -ne 0 -and $output -match "No completions published for channel '1\.5'") {
    Test-Pass 'an unpublished explicit channel is refused'
  }
  else {
    Test-Fail 'an unpublished explicit channel is refused' $output
  }
  Assert-FileMissing 'unpublished channel: nothing was written' $completionPath

  # The same on -DryRun, which fetches nothing and so used to print a plan for
  # a channel that could never be installed.
  $output = Get-FlatOutput (Invoke-Installer -BaseUrl $baseUrl -Arguments @('-Channel', '1.5', '-DryRun'))
  if ($LASTEXITCODE -ne 0 -and $output -match "No completions published for channel '1\.5'" -and
    $output -notmatch 'Would download') {
    Test-Pass 'a dry run refuses an unpublished channel'
  }
  else {
    Test-Fail 'a dry run refuses an unpublished channel' $output
  }

  # The version advisory compares the manifest's Quarto version against
  # whatever quarto reports on PATH. Mirrors the shim-based cases in
  # tests/install.sh; the older-version and patch-only-difference cases are
  # covered there and not repeated here.
  $quartoShimDirectory = Join-Path $scratch 'quarto-shim'
  New-Item -ItemType Directory -Path $quartoShimDirectory -Force | Out-Null

  $releaseManifest = Get-Content -Raw (Join-Path $Site 'completions/release/manifest.json') | ConvertFrom-Json
  $releaseParts = $releaseManifest.quartoVersion -split '\.'
  $releaseMajor = [int]$releaseParts[0]
  $releaseMinor = [int]$releaseParts[1]

  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version "$releaseMajor.$releaseMinor.0"
  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @('-Channel', 'release')
  if ($output -notmatch 'than these completions') { Test-Pass 'advisory: a matching major.minor says nothing' }
  else { Test-Fail 'advisory: a matching major.minor says nothing' $output }

  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version "$releaseMajor.$($releaseMinor + 1).0"
  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @('-Channel', 'release')
  if ($output -match [regex]::Escape('-Channel pre-release')) { Test-Pass 'advisory: a newer Quarto names -Channel pre-release' }
  else { Test-Fail 'advisory: a newer Quarto names -Channel pre-release' $output }

  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version '99.9.9'
  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @('-Channel', 'release')
  if ($output -notmatch 'than these completions') { Test-Pass 'advisory: the dev sentinel says nothing' }
  else { Test-Fail 'advisory: the dev sentinel says nothing' $output }

  $output = Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath '' -Arguments @('-Channel', 'release')
  if ($output -notmatch 'than these completions') { Test-Pass 'advisory: no quarto on PATH says nothing' }
  else { Test-Fail 'advisory: no quarto on PATH says nothing' $output }

  # With no -Channel named, a local Quarto whose own minor is published (1.9,
  # a line below release) is installed instead of release.
  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version '1.9.2'
  $output = Get-FlatOutput (Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @() -SkipChannelPin)
  if ($output -match [regex]::Escape('(1.9 channel)') -and $output -notmatch 'installing the release channel instead') {
    Test-Pass 'auto-detect: a published local minor is installed'
  }
  else {
    Test-Fail 'auto-detect: a published local minor is installed' $output
  }

  # A local minor with nothing published (1.5 is older than every published
  # minor) falls back to release, and says so.
  Write-QuartoShimVersion -Directory $quartoShimDirectory -Version '1.5.0'
  $output = Get-FlatOutput (Invoke-InstallerWithQuarto -BaseUrl $baseUrl -QuartoPath $quartoShimDirectory -Arguments @() -SkipChannelPin)
  if ($output -match 'No published completions for Quarto 1.5. Installing the release channel instead' -and
    $output -match [regex]::Escape('(release channel)')) {
    Test-Pass 'auto-detect: an unpublished local minor falls back to release'
  }
  else {
    Test-Fail 'auto-detect: an unpublished local minor falls back to release' $output
  }

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
