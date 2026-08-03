#!/usr/bin/env bash
#
# Parses every generated script with the shell it targets, and lints the
# installers. Shells that are not installed are reported as skipped.
#
#     tests/syntax.sh [completions-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPLETIONS="$(cd "${1:-${ROOT}/docs/completions/stable}" && pwd)"

# PowerShell reads native Windows paths, not the MSYS ones Git Bash hands out.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
}

PS_ROOT="$(native_path "${ROOT}")"
PS_COMPLETIONS="$(native_path "${COMPLETIONS}")"

PASSED=0
FAILED=0
SKIPPED=0

pass() {
  printf 'ok    %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL  %s\n%s\n' "$1" "$2"
  FAILED=$((FAILED + 1))
}

skip() {
  printf 'skip  %s (%s)\n' "$1" "$2"
  SKIPPED=$((SKIPPED + 1))
}

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
check "install.sh passes shellcheck" shellcheck shellcheck "${ROOT}/docs/install.sh"
check "install.sh is formatted" shfmt shfmt -d -i 2 -ci "${ROOT}/docs/install.sh"
check "tests pass shellcheck" shellcheck \
  shellcheck "${ROOT}/tests/completions.sh" "${ROOT}/tests/syntax.sh"
check "install.ps1 passes PSScriptAnalyzer" pwsh pwsh -NoProfile -Command \
  "Invoke-ScriptAnalyzer -Path '${PS_ROOT}/docs/install.ps1' -EnableExit -Severity Error,Warning"

printf '\n%d passed, %d failed, %d skipped.\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
[ "${FAILED}" -eq 0 ]
