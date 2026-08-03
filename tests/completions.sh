#!/usr/bin/env bash
#
# Functional tests: drive each shell's completion and assert on the candidates
# it produces. Shells that are not installed are reported as skipped rather
# than silently passing.
#
#     tests/completions.sh [completions-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolved before anything changes directory: the bash harness completes from a
# fixture directory, so a relative path would no longer point anywhere.
COMPLETIONS="$(cd "${1:-${ROOT}/docs/completions/stable}" && pwd)"

# PowerShell reads native Windows paths, not the MSYS ones Git Bash hands out.
if command -v cygpath >/dev/null 2>&1; then
  PS_COMPLETIONS="$(cygpath -w "${COMPLETIONS}")"
else
  PS_COMPLETIONS="${COMPLETIONS}"
fi
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

PASSED=0
FAILED=0
SKIPPED=0

pass() {
  printf 'ok    %s\n' "$1"
  PASSED=$((PASSED + 1))
}

fail() {
  printf 'FAIL  %s\n      %s\n' "$1" "$2"
  FAILED=$((FAILED + 1))
}

skip() {
  printf 'skip  %s (%s)\n' "$1" "$2"
  SKIPPED=$((SKIPPED + 1))
}

expect_contains() {
  # $1: label, $2: haystack, $3: needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    pass "$1"
  else
    fail "$1" "expected to find '$3' in: $2"
  fi
}

expect_missing() {
  if printf '%s' "$2" | grep -qF -- "$3"; then
    fail "$1" "expected not to find '$3' in: $2"
  else
    pass "$1"
  fi
}

# Documents the completions filter on, so file candidates can be asserted.
mkdir -p "${SCRATCH}/fixtures/sub"
touch "${SCRATCH}/fixtures/report.qmd" \
  "${SCRATCH}/fixtures/notebook.ipynb" \
  "${SCRATCH}/fixtures/readme.txt"

bash_complete() {
  # $@: the words typed, with an empty final word for "at a fresh argument"
  bash --noprofile --norc -c '
    cd "$2" || exit 1
    source "$1/quarto.bash"
    shift 2
    COMP_WORDS=("$@")
    COMP_CWORD=$(( $# - 1 ))
    COMPREPLY=()
    _quarto
    printf "%s\n" "${COMPREPLY[*]}"
  ' _ "${COMPLETIONS}" "${SCRATCH}/fixtures" "$@"
}

test_bash() {
  if ! command -v bash >/dev/null 2>&1; then
    skip "bash" "not installed"
    return
  fi

  expect_contains "bash: top-level commands" "$(bash_complete quarto '')" "render"
  expect_contains "bash: flags of a command" "$(bash_complete quarto render '--t')" "--to"
  expect_contains "bash: formats for --to" "$(bash_complete quarto render --to '')" "revealjs"
  expect_contains "bash: log levels" "$(bash_complete quarto render --log-level '')" "critical"
  expect_contains "bash: publish providers" "$(bash_complete quarto publish '')" "gh-pages"
  expect_contains "bash: forwarded pandoc flags" "$(bash_complete quarto render --pdf-en)" "--pdf-engine"

  local inputs
  inputs="$(bash_complete quarto render '')"
  expect_contains "bash: input documents" "${inputs}" "report.qmd"
  expect_missing "bash: unrelated files filtered out" "${inputs}" "readme.txt"

  expect_missing "bash: provider not offered twice" \
    "$(bash_complete quarto publish gh-pages '')" "quarto-pub"

  # bash 3.2 rejects a negative array subscript, which is what completing at
  # position zero would ask for.
  if bash_complete quarto >/dev/null 2>&1; then
    pass "bash: completing the command name itself does not error"
  else
    fail "bash: completing the command name itself does not error" "the function exited non-zero"
  fi
}

test_zsh() {
  if ! command -v zsh >/dev/null 2>&1; then
    skip "zsh" "not installed"
    return
  fi

  local completed candidates
  completed="$(zsh "${ROOT}/tests/zsh-complete.zsh" "${COMPLETIONS}" "${SCRATCH}/zsh" 'quarto ren')"
  expect_contains "zsh: completes a command name" "${completed}" "quarto render"

  candidates="$(zsh "${ROOT}/tests/zsh-complete.zsh" "${COMPLETIONS}" "${SCRATCH}/zsh" 'quarto render --to ' 2)"
  expect_contains "zsh: formats for --to" "${candidates}" "revealjs"
}

test_fish() {
  if ! command -v fish >/dev/null 2>&1; then
    skip "fish" "not installed"
    return
  fi

  local script="${SCRATCH}/fish.fish"
  cat >"${script}" <<EOF
source ${COMPLETIONS}/quarto.fish
function quarto; end
echo "COMMANDS:"(complete -C 'quarto ')
echo "FORMATS:"(complete -C 'quarto render --to ')
echo "PROVIDERS:"(complete -C 'quarto publish ')
echo "AFTER:"(complete -C 'quarto publish gh-pages ')
EOF
  local output
  output="$(fish "${script}" 2>&1)"

  expect_contains "fish: top-level commands" "${output}" "render"
  expect_contains "fish: formats for --to" "${output}" "revealjs"
  expect_contains "fish: publish providers" "${output}" "gh-pages"
  expect_missing "fish: provider not offered twice" \
    "$(printf '%s' "${output}" | grep '^AFTER:' || true)" "quarto-pub"
}

test_pwsh() {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip "pwsh" "not installed"
    return
  fi

  local output
  output="$(pwsh -NoProfile -Command "
    . '${PS_COMPLETIONS}/quarto.ps1'
    function Complete-Line { param([string]\$Line)
      (TabExpansion2 \$Line \$Line.Length).CompletionMatches.CompletionText -join ' '
    }
    'COMMANDS:' + (Complete-Line 'quarto ')
    'PARTIAL:' + (Complete-Line 'quarto ren')
    'FORMATS:' + (Complete-Line 'quarto render --to ')
    'PROVIDERS:' + (Complete-Line 'quarto publish ')
    'AFTER:' + (Complete-Line 'quarto publish gh-pages ')
  " 2>&1)"

  expect_contains "pwsh: top-level commands" "${output}" "render"
  expect_contains "pwsh: a single partial word completes" \
    "$(printf '%s' "${output}" | grep '^PARTIAL:' || true)" "render"
  expect_contains "pwsh: formats for --to" "${output}" "revealjs"
  expect_contains "pwsh: publish providers" "${output}" "gh-pages"
  expect_missing "pwsh: provider not offered twice" \
    "$(printf '%s' "${output}" | grep '^AFTER:' || true)" "quarto-pub"
}

test_bash
test_zsh
test_fish
test_pwsh

printf '\n%d passed, %d failed, %d skipped.\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
[ "${FAILED}" -eq 0 ]
