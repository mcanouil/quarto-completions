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
install_run() {
  env -u ZSH -u ZSH_CUSTOM \
    HOME="${HOME_DIR}" \
    XDG_DATA_HOME="${HOME_DIR}/.local/share" \
    XDG_CONFIG_HOME="${HOME_DIR}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" "$@"
}

# A dry run reports without touching anything.
install_run --shell zsh --dry-run >/dev/null
expect_absent "dry run writes nothing" "${HOME_DIR}/.local/share/zsh/site-functions/_quarto"
expect_absent "dry run leaves the rc file alone" "${HOME_DIR}/.zshrc"

for shell in bash zsh fish; do
  if install_run --shell "${shell}" >/dev/null; then
    pass "${shell}: install succeeds"
  else
    fail "${shell}: install succeeds" "installer exited non-zero"
  fi
done

expect_file "bash: script installed" "${HOME_DIR}/.local/share/quarto-completions/quarto.bash"
expect_file "zsh: script installed" "${HOME_DIR}/.local/share/zsh/site-functions/_quarto"
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
    HOME="${HOME_DIR}" \
    XDG_DATA_HOME="${HOME_DIR}/.local/share" \
    XDG_CONFIG_HOME="${HOME_DIR}/.config" \
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
expect_absent "zsh: script removed" "${HOME_DIR}/.local/share/zsh/site-functions/_quarto"
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

# Installing Oh My Zsh after the fact moves where the file belongs. The run
# that notices has to take the old one with it, block included, or the machine
# keeps a copy that nothing updates.
MIGRATE_HOME="$(scenario_home migrate-zsh)"
scenario_run "${MIGRATE_HOME}" --shell zsh >/dev/null
expect_file "zsh migration: starts in site-functions" \
  "${MIGRATE_HOME}/.local/share/zsh/site-functions/_quarto"
mkdir -p "${MIGRATE_HOME}/.oh-my-zsh/custom"
scenario_run "${MIGRATE_HOME}" --shell zsh >/dev/null
expect_file "zsh migration: moves to the custom directory" \
  "${MIGRATE_HOME}/.oh-my-zsh/custom/completions/_quarto"
expect_absent "zsh migration: the old script is gone" \
  "${MIGRATE_HOME}/.local/share/zsh/site-functions/_quarto"
expect_count "zsh migration: the old rc block is gone" \
  "${MIGRATE_HOME}/.zshrc" ">>> quarto completions >>>" 0

# The same shape for bash, and the case that was broken before any of this:
# installing bash-completion later switches the branch, and the previous run's
# script and rc block were both left behind.
MIGRATE_BASH="$(scenario_home migrate-bash)"
scenario_run "${MIGRATE_BASH}" --shell bash >/dev/null
expect_file "bash migration: starts in quarto-completions" \
  "${MIGRATE_BASH}/.local/share/quarto-completions/quarto.bash"
mkdir -p "${MIGRATE_BASH}/.local/share/bash-completion/completions"
scenario_run "${MIGRATE_BASH}" --shell bash >/dev/null
expect_file "bash migration: moves to bash-completion" \
  "${MIGRATE_BASH}/.local/share/bash-completion/completions/quarto"
expect_absent "bash migration: the old script is gone" \
  "${MIGRATE_BASH}/.local/share/quarto-completions/quarto.bash"
expect_count "bash migration: the old rc block is gone" \
  "${MIGRATE_BASH}/.bashrc" ">>> quarto completions >>>" 0

# Uninstalling sweeps every location, not only the one that resolves now.
scenario_run "${MIGRATE_BASH}" --shell bash --uninstall >/dev/null
expect_absent "uninstall: sweeps the resolved location" \
  "${MIGRATE_BASH}/.local/share/bash-completion/completions/quarto"

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
