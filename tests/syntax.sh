#!/usr/bin/env bash
#
# Parses every generated script with the shell it targets, and lints the
# installers and the test scripts. Shells that are not installed are reported
# as skipped.
#
#     tests/syntax.sh [completions-directory] [--scripts-only]
#
# The installer and test lints do not read the completions directory, so a
# second channel is checked with --scripts-only rather than repeating them,
# which would mean a second cold PowerShell start.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPLETIONS="$(cd "${1:-${ROOT}/docs/completions/stable}" && pwd)"
SCRIPTS_ONLY=0
[ "${2:-}" = "--scripts-only" ] && SCRIPTS_ONLY=1

# shellcheck source=tests/lib.sh
. "${ROOT}/tests/lib.sh"

PS_ROOT="$(native_path "${ROOT}")"
PS_COMPLETIONS="$(native_path "${COMPLETIONS}")"

check() {
  # $1: label, $2: required command, $3...: the command to run
  local label="$1" required="$2"
  shift 2
  if ! command -v "${required}" >/dev/null 2>&1; then
    skip "${label}" "${required} not installed"
    return
  fi
  local output
  if output="$("$@" 2>&1)"; then
    pass "${label}"
  else
    fail "${label}" "${output}"
  fi
}

check "bash: completion script parses" bash bash -n "${COMPLETIONS}/quarto.bash"
check "zsh: completion script parses" zsh zsh -n "${COMPLETIONS}/_quarto"
check "fish: completion script parses" fish fish --no-execute "${COMPLETIONS}/quarto.fish"
check "pwsh: completion script parses" pwsh pwsh -NoProfile -Command \
  "\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('${PS_COMPLETIONS}/quarto.ps1', [ref]\$null, [ref]\$errors) | Out-Null; if (\$errors) { \$errors; exit 1 }"

check "bash: completion script passes shellcheck" shellcheck \
  shellcheck -s bash "${COMPLETIONS}/quarto.bash"

if [ "${SCRIPTS_ONLY}" = "0" ]; then
  check "install.sh passes shellcheck" shellcheck shellcheck "${ROOT}/docs/install.sh"
  check "install.sh is formatted" shfmt shfmt -d -i 2 -ci "${ROOT}/docs/install.sh"
  check "tests pass shellcheck" shellcheck shellcheck \
    "${ROOT}/tests/completions.sh" \
    "${ROOT}/tests/install.sh" \
    "${ROOT}/tests/lib.sh" \
    "${ROOT}/tests/syntax.sh"
  check "install.ps1 passes PSScriptAnalyzer" pwsh pwsh -NoProfile -Command \
    "Invoke-ScriptAnalyzer -Path '${PS_ROOT}/docs/install.ps1' -EnableExit -Severity Error,Warning"
fi

summary
