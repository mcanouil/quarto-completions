#!/usr/bin/env bash
#
# Shared harness for the shell test scripts: counters, reporting, and the path
# handling every one of them needs. Sourced, never executed.

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

# Prints the tally and returns the exit status the script should end on.
summary() {
  printf '\n%d passed, %d failed, %d skipped.\n' "${PASSED}" "${FAILED}" "${SKIPPED}"
  [ "${FAILED}" -eq 0 ]
}

# PowerShell reads native Windows paths, not the MSYS ones Git Bash hands out.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1"
  else
    printf '%s' "$1"
  fi
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
