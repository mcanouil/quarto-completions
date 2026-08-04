#!/usr/bin/env bash
#
# End-to-end installer test. Serves the rendered site locally, installs into a
# throwaway home directory, and asserts what landed where, that a second run
# changes nothing, and that uninstalling leaves no residue.
#
#     tests/install.sh [site-directory]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${1:-${ROOT}/docs/_site}"
[ -d "${SITE}" ] && SITE="$(cd "${SITE}" && pwd)"

# shellcheck source=tests/lib.sh
. "${ROOT}/tests/lib.sh"
PORT="${QUARTO_COMPLETIONS_TEST_PORT:-8799}"
SCRATCH="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [ -n "${SERVER_PID}" ]; then
    kill "${SERVER_PID}" 2>/dev/null || true
  fi
  rm -rf "${SCRATCH}"
}
trap cleanup EXIT

expect_file() {
  if [ -f "$2" ]; then
    pass "$1"
  else
    fail "$1" "missing file: $2"
  fi
}

expect_absent() {
  if [ -e "$2" ]; then
    fail "$1" "expected to be gone: $2"
  else
    pass "$1"
  fi
}

expect_count() {
  # $1: label, $2: file, $3: needle, $4: expected occurrences
  local actual
  actual="$(grep -cF -- "$3" "$2" || true)"
  if [ "${actual}" = "$4" ]; then
    pass "$1"
  else
    fail "$1" "expected $4 occurrences of '$3' in $2, found ${actual}"
  fi
}

[ -d "${SITE}" ] || {
  printf 'error: no rendered site at %s (run: quarto render docs)\n' "${SITE}" >&2
  exit 1
}

python3 -m http.server "${PORT}" --directory "${SITE}" >/dev/null 2>&1 &
SERVER_PID=$!

# Wait for the server to accept connections rather than guessing at a delay,
# which a loaded runner loses.
ready=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/completions/stable/manifest.json" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "${ready}" != "1" ]; then
  printf 'error: the local server never answered on port %s\n' "${PORT}" >&2
  exit 1
fi

HOME_DIR="${SCRATCH}/home"
mkdir -p "${HOME_DIR}"

# -u ZSH -u ZSH_CUSTOM: Oh My Zsh exports both, and the installer honours them
# ahead of $HOME, so a developer running this suite from an Oh My Zsh shell
# would otherwise have the installer reach out of the throwaway home and write
# into their own ~/.oh-my-zsh. Every scenario that wants that layout builds it
# under its own home instead.
#
# HOMEBREW_PREFIX is pointed at a directory that does not exist for the same
# reason: it is authoritative when set, so this keeps a developer's real
# /opt/homebrew out of every scenario but the one that asks for it.
install_run() {
  env -u ZSH -u ZSH_CUSTOM \
    HOME="${HOME_DIR}" \
    HOMEBREW_PREFIX="${HOME_DIR}/no-brew" \
    XDG_DATA_HOME="${HOME_DIR}/.local/share" \
    XDG_CONFIG_HOME="${HOME_DIR}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" "$@"
}

# A dry run reports without touching anything.
install_run --shell zsh --dry-run >/dev/null
expect_absent "dry run writes nothing" "${HOME_DIR}/.zfunc/_quarto"
expect_absent "dry run leaves the rc file alone" "${HOME_DIR}/.zshrc"

for shell in bash zsh fish; do
  if install_run --shell "${shell}" >/dev/null; then
    pass "${shell}: install succeeds"
  else
    fail "${shell}: install succeeds" "installer exited non-zero"
  fi
done

expect_file "bash: script installed" "${HOME_DIR}/.local/share/quarto-completions/quarto.bash"
expect_file "zsh: script installed" "${HOME_DIR}/.zfunc/_quarto"
expect_file "fish: script installed" "${HOME_DIR}/.config/fish/completions/quarto.fish"
expect_file "bash: rc block written" "${HOME_DIR}/.bashrc"
expect_file "zsh: rc block written" "${HOME_DIR}/.zshrc"
expect_absent "fish: no rc file needed" "${HOME_DIR}/.config/fish/config.fish"

# Re-running replaces the managed block rather than appending a second one.
install_run --shell zsh >/dev/null
install_run --shell bash >/dev/null
expect_count "zsh: rc block is not duplicated" "${HOME_DIR}/.zshrc" ">>> quarto completions >>>" 1
expect_count "bash: rc block is not duplicated" "${HOME_DIR}/.bashrc" ">>> quarto completions >>>" 1

if install_run --shell zsh --channel nonsense >/dev/null 2>&1; then
  fail "an unknown channel is refused" "installer exited zero"
else
  pass "an unknown channel is refused"
fi

# A download that no longer matches the manifest is refused. Serve a copy of
# the site whose fish script has been altered after the checksums were written.
#
# Into a home of its own, because a script already installed and already
# matching the manifest is not downloaded again, and this has to reach the
# download to say anything about it.
TAMPERED_HOME="${SCRATCH}/tampered-home"
mkdir -p "${TAMPERED_HOME}"
TAMPERED="${SCRATCH}/tampered"
cp -R "${SITE}" "${TAMPERED}"
printf '\n# tampered\n' >>"${TAMPERED}/completions/stable/quarto.fish"
python3 -m http.server "$((PORT + 1))" --directory "${TAMPERED}" >/dev/null 2>&1 &
TAMPERED_PID=$!
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$((PORT + 1))/completions/stable/manifest.json" >/dev/null 2>&1 && break
  sleep 1
done

tampered_output="$(
  env -u ZSH -u ZSH_CUSTOM \
    HOME="${TAMPERED_HOME}" \
    HOMEBREW_PREFIX="${TAMPERED_HOME}/no-brew" \
    XDG_DATA_HOME="${TAMPERED_HOME}/.local/share" \
    XDG_CONFIG_HOME="${TAMPERED_HOME}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:$((PORT + 1))" --shell fish 2>&1
)" && tampered_status=0 || tampered_status=1
kill "${TAMPERED_PID}" 2>/dev/null || true

if [ "${tampered_status}" = "1" ]; then
  expect_contains "a checksum mismatch is refused" "${tampered_output}" "checksum mismatch"
else
  fail "a checksum mismatch is refused" "installer exited zero: ${tampered_output}"
fi

for shell in bash zsh fish; do
  install_run --shell "${shell}" --uninstall >/dev/null
done

expect_absent "bash: script removed" "${HOME_DIR}/.local/share/quarto-completions/quarto.bash"
expect_absent "zsh: script removed" "${HOME_DIR}/.zfunc/_quarto"
expect_absent "fish: script removed" "${HOME_DIR}/.config/fish/completions/quarto.fish"
expect_count "zsh: rc block removed" "${HOME_DIR}/.zshrc" ">>> quarto completions >>>" 0
expect_count "bash: rc block removed" "${HOME_DIR}/.bashrc" ">>> quarto completions >>>" 0

# Each scenario below gets a home of its own. The one above is reused across
# runs, and giving it an Oh My Zsh layout partway through would change what the
# assertions already made mean.
scenario_home() {
  # $1: name
  local home="${SCRATCH}/$1"
  mkdir -p "${home}"
  printf '%s' "${home}"
}

scenario_run() {
  # $1: home, then installer arguments
  local home="$1"
  shift
  env -u ZSH -u ZSH_CUSTOM \
    HOME="${home}" \
    HOMEBREW_PREFIX="${home}/no-brew" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CONFIG_HOME="${home}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" "$@"
}

# The same, with a Homebrew prefix that exists. Its site-functions directory is
# on fpath already, so the file goes there and .zshrc is left alone.
brew_run() {
  # $1: home, $2: prefix, then installer arguments
  local home="$1" prefix="$2"
  shift 2
  env -u ZSH -u ZSH_CUSTOM \
    HOME="${home}" \
    HOMEBREW_PREFIX="${prefix}" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CONFIG_HOME="${home}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" "$@"
}

# Oh My Zsh already puts its custom completions directory on fpath and runs
# compinit itself, so the file is all that is needed and .zshrc is left alone.
OMZ_HOME="$(scenario_home omz)"
mkdir -p "${OMZ_HOME}/.oh-my-zsh/custom"
scenario_run "${OMZ_HOME}" --shell zsh >/dev/null
expect_file "oh-my-zsh: script installed in the custom directory" \
  "${OMZ_HOME}/.oh-my-zsh/custom/completions/_quarto"
expect_absent "oh-my-zsh: no rc file written" "${OMZ_HOME}/.zshrc"

# An install already on disk is updated where it is. Installing Oh My Zsh
# afterwards changes where a first install would go, and changes nothing for a
# machine that already has one: moving the file would undo a location the user
# may have chosen, and the fpath line that reaches it is still in .zshrc.
STICKY_HOME="$(scenario_home sticky-zsh)"
scenario_run "${STICKY_HOME}" --shell zsh >/dev/null
expect_file "zsh: a first install goes to ~/.zfunc" "${STICKY_HOME}/.zfunc/_quarto"
mkdir -p "${STICKY_HOME}/.oh-my-zsh/custom"
sticky_output="$(scenario_run "${STICKY_HOME}" --shell zsh)"
expect_file "zsh: the existing install is kept where it is" \
  "${STICKY_HOME}/.zfunc/_quarto"
expect_absent "zsh: the newly applicable location is left empty" \
  "${STICKY_HOME}/.oh-my-zsh/custom/completions/_quarto"
expect_contains "zsh: an existing install is reported as one" \
  "${sticky_output}" "Updating existing install"
expect_count "zsh: the rc block that reaches it is kept" \
  "${STICKY_HOME}/.zshrc" ">>> quarto completions >>>" 1

# The same shape for bash: installing bash-completion later does not move a
# script that is already installed and already sourced.
STICKY_BASH="$(scenario_home sticky-bash)"
scenario_run "${STICKY_BASH}" --shell bash >/dev/null
expect_file "bash: a first install goes to quarto-completions" \
  "${STICKY_BASH}/.local/share/quarto-completions/quarto.bash"
mkdir -p "${STICKY_BASH}/.local/share/bash-completion/completions"
scenario_run "${STICKY_BASH}" --shell bash >/dev/null
expect_file "bash: the existing install is kept where it is" \
  "${STICKY_BASH}/.local/share/quarto-completions/quarto.bash"
expect_absent "bash: the newly applicable location is left empty" \
  "${STICKY_BASH}/.local/share/bash-completion/completions/quarto"

# Two locations holding a file is what an install made by an earlier version,
# followed by one made by hand, leaves behind. The higher-precedence one wins
# and the other goes, so nothing is left to shadow the file that is maintained.
SWEEP_HOME="$(scenario_home sweep-zsh)"
mkdir -p "${SWEEP_HOME}/.oh-my-zsh/custom/completions" \
  "${SWEEP_HOME}/.local/share/zsh/site-functions"
touch "${SWEEP_HOME}/.oh-my-zsh/custom/completions/_quarto" \
  "${SWEEP_HOME}/.local/share/zsh/site-functions/_quarto"
scenario_run "${SWEEP_HOME}" --shell zsh >/dev/null
expect_file "zsh: the highest-precedence install is the one updated" \
  "${SWEEP_HOME}/.oh-my-zsh/custom/completions/_quarto"
expect_absent "zsh: the 0.1.x location is swept" \
  "${SWEEP_HOME}/.local/share/zsh/site-functions/_quarto"

# The XDG directory is swept, never kept: a file there is what an earlier
# version of these instructions produced, and an install that settled on it
# would stay exactly where it is meant to move off.
MIGRATE_XDG="$(scenario_home migrate-xdg)"
mkdir -p "${MIGRATE_XDG}/.local/share/zsh/site-functions"
touch "${MIGRATE_XDG}/.local/share/zsh/site-functions/_quarto"
scenario_run "${MIGRATE_XDG}" --shell zsh >/dev/null
expect_file "zsh: a file in the old directory is moved to ~/.zfunc" \
  "${MIGRATE_XDG}/.zfunc/_quarto"
expect_absent "zsh: the old directory is not settled on" \
  "${MIGRATE_XDG}/.local/share/zsh/site-functions/_quarto"

# Homebrew's site-functions directory is on fpath already, so a file written
# there needs no managed block. $HOMEBREW_PREFIX is authoritative when set.
BREW_HOME="$(scenario_home brew)"
BREW_PREFIX="${SCRATCH}/brew"
mkdir -p "${BREW_PREFIX}/share/zsh/site-functions"
brew_run "${BREW_HOME}" "${BREW_PREFIX}" --shell zsh >/dev/null
expect_file "homebrew: script installed in the prefix" \
  "${BREW_PREFIX}/share/zsh/site-functions/_quarto"
expect_absent "homebrew: no rc file written" "${BREW_HOME}/.zshrc"
expect_absent "homebrew: nothing written to ~/.zfunc" "${BREW_HOME}/.zfunc/_quarto"
brew_run "${BREW_HOME}" "${BREW_PREFIX}" --shell zsh --uninstall >/dev/null
expect_absent "homebrew: uninstall removes it from the prefix" \
  "${BREW_PREFIX}/share/zsh/site-functions/_quarto"

# A second install over an unchanged release downloads the script for nothing
# and rewrites a file that is already right. The manifest says so before the
# download, so it is skipped and said out loud.
CURRENT_HOME="$(scenario_home already-current)"
scenario_run "${CURRENT_HOME}" --shell fish >/dev/null
current_output="$(scenario_run "${CURRENT_HOME}" --shell fish)"
expect_contains "an unchanged script is not rewritten" \
  "${current_output}" "Already current"

# Uninstalling sweeps every location, not only the one that resolves now. Put a
# file back in the branch that no longer resolves, so that removing just the
# resolved one would leave something behind.
MIGRATE_BASH="$(scenario_home uninstall-bash)"
mkdir -p "${MIGRATE_BASH}/.local/share/bash-completion/completions"
scenario_run "${MIGRATE_BASH}" --shell bash >/dev/null
expect_file "uninstall: the resolved location is written first" \
  "${MIGRATE_BASH}/.local/share/bash-completion/completions/quarto"
mkdir -p "${MIGRATE_BASH}/.local/share/quarto-completions"
touch "${MIGRATE_BASH}/.local/share/quarto-completions/quarto.bash"
printf '%s\n%s\n%s\n' \
  "# >>> quarto completions >>>" "stale" "# <<< quarto completions <<<" \
  >>"${MIGRATE_BASH}/.bashrc"
scenario_run "${MIGRATE_BASH}" --shell bash --uninstall >/dev/null
expect_absent "uninstall: removes the resolved location" \
  "${MIGRATE_BASH}/.local/share/bash-completion/completions/quarto"
expect_absent "uninstall: removes the location that no longer resolves" \
  "${MIGRATE_BASH}/.local/share/quarto-completions/quarto.bash"
expect_count "uninstall: removes the block the resolved branch never writes" \
  "${MIGRATE_BASH}/.bashrc" ">>> quarto completions >>>" 0

# $ZSH and $ZSH_CUSTOM are exported by Oh My Zsh, so they reach a child whose
# HOME is something else. Following them there would mean installing into, and
# on uninstall deleting from, a home the user did not name.
OUTSIDE="$(scenario_home outside)"
SANDBOX="$(scenario_home sandbox)"
mkdir -p "${OUTSIDE}/.oh-my-zsh/custom/completions"
printf 'not ours to delete\n' >"${OUTSIDE}/.oh-my-zsh/custom/completions/_quarto"
env ZSH="${OUTSIDE}/.oh-my-zsh" \
  HOME="${SANDBOX}" \
  HOMEBREW_PREFIX="${SANDBOX}/no-brew" \
  XDG_DATA_HOME="${SANDBOX}/.local/share" \
  XDG_CONFIG_HOME="${SANDBOX}/.config" \
  bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" \
  --shell zsh --uninstall >/dev/null
expect_file "an out-of-home ZSH is not followed on uninstall" \
  "${OUTSIDE}/.oh-my-zsh/custom/completions/_quarto"

env ZSH="${OUTSIDE}/.oh-my-zsh" \
  HOME="${SANDBOX}" \
  HOMEBREW_PREFIX="${SANDBOX}/no-brew" \
  XDG_DATA_HOME="${SANDBOX}/.local/share" \
  XDG_CONFIG_HOME="${SANDBOX}/.config" \
  bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" \
  --shell zsh >/dev/null
expect_file "an out-of-home ZSH is not followed on install" \
  "${SANDBOX}/.zfunc/_quarto"
expect_count "the out-of-home file is still untouched" \
  "${OUTSIDE}/.oh-my-zsh/custom/completions/_quarto" "not ours to delete" 1

# A home whose script is already gone but whose block is not must not report
# that it cleaned the rc file and then that there was nothing to remove.
RESIDUE_HOME="$(scenario_home residue)"
printf '%s\n%s\n%s\n' \
  "# >>> quarto completions >>>" "stale" "# <<< quarto completions <<<" \
  >"${RESIDUE_HOME}/.zshrc"
residue_output="$(scenario_run "${RESIDUE_HOME}" --shell zsh --uninstall)"
expect_contains "a leftover block alone is still removed" "${residue_output}" "Cleaned"
expect_missing "a removed block does not also report nothing to remove" \
  "${residue_output}" "Nothing to remove"

# --dry-run is the first diagnostic the troubleshooting page asks for, so it
# has to say something even when there is nothing to do.
CLEAN_HOME="$(scenario_home clean)"
clean_output="$(scenario_run "${CLEAN_HOME}" --shell zsh --uninstall --dry-run)"
expect_contains "a dry-run uninstall on a clean home still reports" \
  "${clean_output}" "Nothing to remove"

# The managed block has to work in the shell it is written for. A user who
# already calls compinit is the ordinary case, not an edge one: the block is
# appended below their call, so whatever it does has to work with a dump
# already on disk.
if command -v zsh >/dev/null 2>&1; then
  RC_HOME="$(scenario_home rc)"
  cat >"${RC_HOME}/.zshrc" <<'EOF'
autoload -Uz compinit
compinit -d "${ZDOTDIR:-$HOME}/.zcompdump"
EOF
  scenario_run "${RC_HOME}" --shell zsh >/dev/null
  rc_completed="$(zsh "${ROOT}/tests/zsh-complete.zsh" rc "${RC_HOME}" 'quarto ren')"
  expect_contains "zsh: the managed block makes completions work" "${rc_completed}" "quarto render"
else
  skip "zsh: the managed block makes completions work" "zsh not installed"
fi

summary
