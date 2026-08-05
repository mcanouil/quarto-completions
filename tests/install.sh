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

expect_symlink() {
  if [ -L "$2" ]; then
    pass "$1"
  else
    fail "$1" "not a symlink any more: $2"
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
  if curl -fsS "http://127.0.0.1:${PORT}/completions/release/manifest.json" >/dev/null 2>&1; then
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
#
# -u QUARTO_COMPLETIONS_UNINSTALL: unlike --channel, --shell, and --base-url,
# there is no flag that overrides this once the installer reads it as "1", so
# a developer with it exported would otherwise have every "install succeeds"
# scenario below silently uninstall instead, with no argument able to say
# otherwise.
#
# --channel release is a default, not a fixed value: the installer keeps the
# last --channel it sees, so a caller appending its own after "$@" still
# overrides it. Without this, every scenario below would silently follow
# whatever quarto happens to be on the machine running the suite.
install_run() {
  env -u ZSH -u ZSH_CUSTOM -u QUARTO_COMPLETIONS_UNINSTALL \
    HOME="${HOME_DIR}" \
    HOMEBREW_PREFIX="${HOME_DIR}/no-brew" \
    XDG_DATA_HOME="${HOME_DIR}/.local/share" \
    XDG_CONFIG_HOME="${HOME_DIR}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" --channel release "$@"
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

# A shell named explicitly is validated exactly as a detected one is. Without
# that, the run reaches the download with an empty file name and dies on a
# checksum error that says nothing about the real mistake.
if shell_output="$(install_run --shell nonsense 2>&1)"; then
  fail "an unknown shell is refused" "installer exited zero: ${shell_output}"
else
  expect_contains "an unknown shell is refused" "${shell_output}" "pass --shell bash|zsh|fish"
fi

# Uninstalling never reaches a download, so a typo here used to exit zero after
# reporting "Nothing to remove", which reads as "nothing was installed" rather
# than "that is not a shell".
if shell_output="$(install_run --shell nonsense --uninstall 2>&1)"; then
  fail "an unknown shell is refused on uninstall" "installer exited zero: ${shell_output}"
else
  expect_contains "an unknown shell is refused on uninstall" \
    "${shell_output}" "pass --shell bash|zsh|fish"
fi

# The environment equivalent, which is the only form the piped `curl | bash`
# invocation can use, is validated the same way.
if shell_output="$(QUARTO_COMPLETIONS_SHELL=weird install_run 2>&1)"; then
  fail "an unknown shell from the environment is refused" "installer exited zero: ${shell_output}"
else
  expect_contains "an unknown shell from the environment is refused" \
    "${shell_output}" "pass --shell bash|zsh|fish"
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
printf '\n# tampered\n' >>"${TAMPERED}/completions/release/quarto.fish"
python3 -m http.server "$((PORT + 1))" --directory "${TAMPERED}" >/dev/null 2>&1 &
TAMPERED_PID=$!
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$((PORT + 1))/completions/release/manifest.json" >/dev/null 2>&1 && break
  sleep 1
done

# --channel release is explicit rather than relying on the default: this test
# asserts on the file tampered above, and the default channel would otherwise
# follow whatever quarto happens to be on the machine running the suite.
tampered_output="$(
  env -u ZSH -u ZSH_CUSTOM -u QUARTO_COMPLETIONS_UNINSTALL \
    HOME="${TAMPERED_HOME}" \
    HOMEBREW_PREFIX="${TAMPERED_HOME}/no-brew" \
    XDG_DATA_HOME="${TAMPERED_HOME}/.local/share" \
    XDG_CONFIG_HOME="${TAMPERED_HOME}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:$((PORT + 1))" \
    --shell fish --channel release 2>&1
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

# --channel release is a default, not a fixed value; see install_run above.
scenario_run() {
  # $1: home, then installer arguments
  local home="$1"
  shift
  env -u ZSH -u ZSH_CUSTOM -u QUARTO_COMPLETIONS_UNINSTALL \
    HOME="${home}" \
    HOMEBREW_PREFIX="${home}/no-brew" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CONFIG_HOME="${home}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" --channel release "$@"
}

# The same, with a Homebrew prefix that exists. Its site-functions directory is
# on fpath already, so the file goes there and .zshrc is left alone.
brew_run() {
  # $1: home, $2: prefix, then installer arguments
  local home="$1" prefix="$2"
  shift 2
  env -u ZSH -u ZSH_CUSTOM -u QUARTO_COMPLETIONS_UNINSTALL \
    HOME="${home}" \
    HOMEBREW_PREFIX="${prefix}" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CONFIG_HOME="${home}/.config" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" --channel release "$@"
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

# A stale copy in a directory nobody can write to, which is what Homebrew's
# prefix or a system package leaves behind. The install has otherwise worked,
# so it says what it could not remove and still succeeds.
UNREMOVABLE="$(scenario_home unremovable)"
mkdir -p "${UNREMOVABLE}/.local/share/zsh/site-functions"
touch "${UNREMOVABLE}/.local/share/zsh/site-functions/_quarto"
chmod 500 "${UNREMOVABLE}/.local/share/zsh/site-functions"
if unremovable_output="$(scenario_run "${UNREMOVABLE}" --shell zsh 2>&1)"; then
  pass "an unremovable stale copy does not fail the install"
else
  fail "an unremovable stale copy does not fail the install" "${unremovable_output}"
fi
expect_file "the install still lands" "${UNREMOVABLE}/.zfunc/_quarto"
expect_contains "it says what it could not remove" \
  "${unremovable_output}" "Could not remove"
chmod 700 "${UNREMOVABLE}/.local/share/zsh/site-functions"

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
env -u QUARTO_COMPLETIONS_UNINSTALL ZSH="${OUTSIDE}/.oh-my-zsh" \
  HOME="${SANDBOX}" \
  HOMEBREW_PREFIX="${SANDBOX}/no-brew" \
  XDG_DATA_HOME="${SANDBOX}/.local/share" \
  XDG_CONFIG_HOME="${SANDBOX}/.config" \
  bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" \
  --shell zsh --uninstall >/dev/null
expect_file "an out-of-home ZSH is not followed on uninstall" \
  "${OUTSIDE}/.oh-my-zsh/custom/completions/_quarto"

env -u QUARTO_COMPLETIONS_UNINSTALL ZSH="${OUTSIDE}/.oh-my-zsh" \
  HOME="${SANDBOX}" \
  HOMEBREW_PREFIX="${SANDBOX}/no-brew" \
  XDG_DATA_HOME="${SANDBOX}/.local/share" \
  XDG_CONFIG_HOME="${SANDBOX}/.config" \
  bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" \
  --shell zsh --channel release >/dev/null
expect_file "an out-of-home ZSH is not followed on install" \
  "${SANDBOX}/.zfunc/_quarto"
expect_count "the out-of-home file is still untouched" \
  "${OUTSIDE}/.oh-my-zsh/custom/completions/_quarto" "not ours to delete" 1

# A .zshrc that is a symlink, which is what dotfile managers create. Editing
# the managed block must follow the link, not replace it with a plain file.
LINK_HOME="$(scenario_home symlink-rc)"
mkdir -p "${LINK_HOME}/dotfiles"
touch "${LINK_HOME}/dotfiles/zshrc"
ln -s "${LINK_HOME}/dotfiles/zshrc" "${LINK_HOME}/.zshrc"
scenario_run "${LINK_HOME}" --shell zsh >/dev/null
# The second run rewrites the block, which is the path that edits in place.
scenario_run "${LINK_HOME}" --shell zsh >/dev/null
expect_symlink "zsh: a symlinked rc file survives a re-install" "${LINK_HOME}/.zshrc"
expect_count "zsh: the block landed through the symlink" \
  "${LINK_HOME}/dotfiles/zshrc" ">>> quarto completions >>>" 1
scenario_run "${LINK_HOME}" --shell zsh --uninstall >/dev/null
expect_symlink "zsh: a symlinked rc file survives an uninstall" "${LINK_HOME}/.zshrc"
expect_count "zsh: uninstall removed the block through the symlink" \
  "${LINK_HOME}/dotfiles/zshrc" ">>> quarto completions >>>" 0

# An earlier install whose directory has since become read-only, which is what
# a Homebrew prefix owned by another user looks like. Choosing it again would
# download the script and then die on the mv; it has to fall through to a
# location that can be written, and report the copy it could not remove.
ROBREW_HOME="$(scenario_home readonly-brew)"
ROBREW_PREFIX="${SCRATCH}/readonly-brew-prefix"
mkdir -p "${ROBREW_PREFIX}/share/zsh/site-functions"
touch "${ROBREW_PREFIX}/share/zsh/site-functions/_quarto"
chmod 555 "${ROBREW_PREFIX}/share/zsh/site-functions"
if robrew_output="$(brew_run "${ROBREW_HOME}" "${ROBREW_PREFIX}" --shell zsh 2>&1)"; then
  pass "a read-only existing install does not fail the install"
else
  fail "a read-only existing install does not fail the install" "${robrew_output}"
fi
expect_file "the install falls through to a writable location" "${ROBREW_HOME}/.zfunc/_quarto"
expect_contains "the read-only copy is reported" "${robrew_output}" "Could not remove"
chmod 755 "${ROBREW_PREFIX}/share/zsh/site-functions"

# A first install into an unwritable rc file without a managed block reaches
# the append rather than the rewrite, and has to fail with the same message.
ROAPPEND_HOME="$(scenario_home readonly-append)"
touch "${ROAPPEND_HOME}/.zshrc"
chmod 400 "${ROAPPEND_HOME}/.zshrc"
if roappend_output="$(scenario_run "${ROAPPEND_HOME}" --shell zsh 2>&1)"; then
  fail "an unwritable rc file fails a first install" "installer exited zero: ${roappend_output}"
else
  expect_contains "an unwritable rc file is named on a first install" \
    "${roappend_output}" "error: could not write ${ROAPPEND_HOME}/.zshrc"
fi
chmod 600 "${ROAPPEND_HOME}/.zshrc"

# An rc file that cannot be written must stop the run with a message naming
# it, not with a bare permission error from the redirect.
RORC_HOME="$(scenario_home readonly-rc)"
printf '%s\n%s\n%s\n' \
  "# >>> quarto completions >>>" "stale" "# <<< quarto completions <<<" \
  >"${RORC_HOME}/.zshrc"
chmod 400 "${RORC_HOME}/.zshrc"
if rorc_output="$(scenario_run "${RORC_HOME}" --shell zsh --uninstall 2>&1)"; then
  fail "an unwritable rc file fails the run" "installer exited zero: ${rorc_output}"
else
  expect_contains "an unwritable rc file is named in the error" \
    "${rorc_output}" "error: could not write ${RORC_HOME}/.zshrc"
fi
chmod 600 "${RORC_HOME}/.zshrc"

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

# A block whose closing marker is gone, which is what a hand edit, a merge
# conflict, or a half-written file leaves behind. The sed range that removes
# the block runs to the end of the file when it never matches an end marker,
# so everything the user kept below it went with it, on install and uninstall
# alike. Both must stop and say so, and leave the file exactly as it was.
UNTERMINATED_HOME="$(scenario_home unterminated)"
write_unterminated_rc() {
  printf '%s\n%s\n%s\n' \
    "# >>> quarto completions >>>" \
    "fpath=(\"\${HOME}/.zfunc\" \$fpath)" \
    "export SENTINEL=keep-me" \
    >"${UNTERMINATED_HOME}/.zshrc"
}

write_unterminated_rc
if unterminated_output="$(scenario_run "${UNTERMINATED_HOME}" --shell zsh 2>&1)"; then
  fail "an unterminated block fails the install" "installer exited zero: ${unterminated_output}"
else
  expect_contains "an unterminated block is named on install" \
    "${unterminated_output}" "${UNTERMINATED_HOME}/.zshrc"
fi
expect_count "install left the content below the block alone" \
  "${UNTERMINATED_HOME}/.zshrc" "SENTINEL=keep-me" 1

write_unterminated_rc
if unterminated_output="$(scenario_run "${UNTERMINATED_HOME}" --shell zsh --uninstall 2>&1)"; then
  fail "an unterminated block fails the uninstall" "installer exited zero: ${unterminated_output}"
else
  expect_contains "an unterminated block is named on uninstall" \
    "${unterminated_output}" "${UNTERMINATED_HOME}/.zshrc"
fi
expect_count "uninstall left the content below the block alone" \
  "${UNTERMINATED_HOME}/.zshrc" "SENTINEL=keep-me" 1

# --dry-run decided there was a block to clean from the opening marker alone,
# so it promised a clean the run that followed refused. It has to report the
# problem instead, and end the way the real run does.
write_unterminated_rc
if unterminated_output="$(scenario_run "${UNTERMINATED_HOME}" --shell zsh --dry-run 2>&1)"; then
  fail "an unterminated block fails a dry-run install" "installer exited zero: ${unterminated_output}"
else
  expect_contains "a dry-run install names the unterminated block" \
    "${unterminated_output}" "no closing"
  expect_missing "a dry-run install promises no rc file update" \
    "${unterminated_output}" "Would update   ${UNTERMINATED_HOME}/.zshrc"
fi
expect_count "the dry-run install left the content below the block alone" \
  "${UNTERMINATED_HOME}/.zshrc" "SENTINEL=keep-me" 1

write_unterminated_rc
if unterminated_output="$(scenario_run "${UNTERMINATED_HOME}" --shell zsh --uninstall --dry-run 2>&1)"; then
  fail "an unterminated block fails a dry-run uninstall" "installer exited zero: ${unterminated_output}"
else
  expect_contains "a dry-run uninstall names the unterminated block" \
    "${unterminated_output}" "no closing"
  expect_missing "a dry-run uninstall promises no clean" \
    "${unterminated_output}" "Would clean"
fi
expect_count "the dry-run uninstall left the content below the block alone" \
  "${UNTERMINATED_HOME}/.zshrc" "SENTINEL=keep-me" 1

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

# --channel dev fetches from the dev channel published alongside release and
# pre-release: generated from a 99.9.9 quarto-cli source build, and the only
# one that carries the hidden commands (dev-call and the rest).
DEV_HOME="$(scenario_home dev-channel)"
if scenario_run "${DEV_HOME}" --shell fish --channel dev >/dev/null; then
  pass "a dev channel install succeeds"
else
  fail "a dev channel install succeeds" "installer exited non-zero"
fi
expect_file "dev channel: script installed" \
  "${DEV_HOME}/.config/fish/completions/quarto.fish"

# --channel 1.9 fetches an archived minor, published alongside release,
# pre-release, and dev: generated from that line's newest patch.
VERSION_HOME="$(scenario_home version-channel)"
if scenario_run "${VERSION_HOME}" --shell fish --channel 1.9 >/dev/null; then
  pass "a version channel install succeeds"
else
  fail "a version channel install succeeds" "installer exited non-zero"
fi
expect_file "version channel: script installed" \
  "${VERSION_HOME}/.config/fish/completions/quarto.fish"

# A channel naming anything but a bare major.minor is refused the same way an
# unrecognised word is.
if install_run --shell zsh --channel 1.9.3 >/dev/null 2>&1; then
  fail "a three-part version channel is refused" "installer exited zero"
else
  pass "a three-part version channel is refused"
fi

# The version advisory compares the manifest's Quarto version against
# whatever is on PATH. QUARTO_SHIM is prepended ahead of the real quarto
# test.yml installs for the rest of the suite, so each case controls exactly
# what version is seen; path_without_real_quarto strips that real one out
# entirely, standing in for a machine with none.
QUARTO_SHIM="${SCRATCH}/quarto-shim"
mkdir -p "${QUARTO_SHIM}"

set_quarto_shim_version() {
  # $1: version the shim reports
  cat >"${QUARTO_SHIM}/quarto" <<SHIM
#!/usr/bin/env sh
printf '%s\n' "$1"
SHIM
  chmod +x "${QUARTO_SHIM}/quarto"
}

path_without_real_quarto() {
  local real_dir="" entry result=""
  if command -v quarto >/dev/null 2>&1; then
    real_dir="$(dirname "$(command -v quarto)")"
  fi
  IFS=':' read -r -a entries <<<"${PATH}"
  for entry in "${entries[@]}"; do
    if [ -n "${real_dir}" ] && [ "${entry}" = "${real_dir}" ]; then
      continue
    fi
    result="${result:+${result}:}${entry}"
  done
  printf '%s' "${result}"
}

advisory_run() {
  # $1: home, $2: PATH to run with, then installer arguments
  local home="$1" run_path="$2"
  shift 2
  env -u ZSH -u ZSH_CUSTOM -u QUARTO_COMPLETIONS_UNINSTALL \
    HOME="${home}" \
    HOMEBREW_PREFIX="${home}/no-brew" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CONFIG_HOME="${home}/.config" \
    PATH="${run_path}" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" --channel release "$@"
}

RELEASE_QUARTO_VERSION="$(sed -n 's/.*"quartoVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "${SITE}/completions/release/manifest.json" | head -n 1)"
RELEASE_MAJOR="${RELEASE_QUARTO_VERSION%%.*}"
RELEASE_MINOR="${RELEASE_QUARTO_VERSION#*.}"
RELEASE_MINOR="${RELEASE_MINOR%%.*}"
if [ "${RELEASE_MINOR}" -gt 0 ]; then
  LOWER_VERSION="${RELEASE_MAJOR}.$((RELEASE_MINOR - 1)).0"
else
  LOWER_VERSION="$((RELEASE_MAJOR - 1)).9.0"
fi

MATCH_HOME="$(scenario_home advisory-match)"
set_quarto_shim_version "${RELEASE_MAJOR}.${RELEASE_MINOR}.0"
match_output="$(advisory_run "${MATCH_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_missing "advisory: a matching major.minor says nothing" "${match_output}" "than these completions"

PATCH_HOME="$(scenario_home advisory-patch)"
set_quarto_shim_version "${RELEASE_MAJOR}.${RELEASE_MINOR}.99"
patch_output="$(advisory_run "${PATCH_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_missing "advisory: a patch-only difference says nothing" "${patch_output}" "than these completions"

NEWER_HOME="$(scenario_home advisory-newer)"
set_quarto_shim_version "${RELEASE_MAJOR}.$((RELEASE_MINOR + 1)).0"
newer_output="$(advisory_run "${NEWER_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_contains "advisory: a newer Quarto names --channel pre-release" "${newer_output}" "--channel pre-release"

OLDER_HOME="$(scenario_home advisory-older)"
set_quarto_shim_version "${LOWER_VERSION}"
older_output="$(advisory_run "${OLDER_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_contains "advisory: an older Quarto is called out" "${older_output}" "older than these completions"

DEVVER_HOME="$(scenario_home advisory-devver)"
set_quarto_shim_version "99.9.9"
devver_output="$(advisory_run "${DEVVER_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_missing "advisory: the dev sentinel says nothing" "${devver_output}" "than these completions"

NOPATH_HOME="$(scenario_home advisory-nopath)"
rm -f "${QUARTO_SHIM}/quarto"
nopath_output="$(advisory_run "${NOPATH_HOME}" "$(path_without_real_quarto)" --shell fish)"
expect_missing "advisory: no quarto on PATH says nothing" "${nopath_output}" "than these completions"

# Channel auto-detection reads the same PATH-visible quarto as the version
# advisory above, so it reuses the shim; unlike advisory_run, it names no
# --channel of its own, letting resolve_channel's own default run.
autodetect_run() {
  # $1: home, $2: PATH to run with, then installer arguments
  local home="$1" run_path="$2"
  shift 2
  env -u ZSH -u ZSH_CUSTOM -u QUARTO_COMPLETIONS_UNINSTALL \
    HOME="${home}" \
    HOMEBREW_PREFIX="${home}/no-brew" \
    XDG_DATA_HOME="${home}/.local/share" \
    XDG_CONFIG_HOME="${home}/.config" \
    PATH="${run_path}" \
    bash "${ROOT}/docs/install.sh" --base-url "http://127.0.0.1:${PORT}" "$@"
}

# With no --channel named, a local Quarto whose own minor is published (1.9,
# backfilled alongside release) is installed instead of release.
MINORMATCH_HOME="$(scenario_home minor-match)"
set_quarto_shim_version "1.9.2"
minormatch_output="$(autodetect_run "${MINORMATCH_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_contains "auto-detect: a published local minor is installed" "${minormatch_output}" "(1.9 channel)"
expect_missing "auto-detect: no fallback note for a published minor" \
  "${minormatch_output}" "installing the release channel instead"

# A local minor with nothing published (1.5 is older than every backfilled
# archive) falls back to release, and says so.
NOMINOR_HOME="$(scenario_home minor-fallback)"
set_quarto_shim_version "1.5.0"
nominor_output="$(autodetect_run "${NOMINOR_HOME}" "${QUARTO_SHIM}:${PATH}" --shell fish)"
expect_contains "auto-detect: an unpublished local minor falls back to release" \
  "${nominor_output}" "No published completions for Quarto 1.5; installing the release channel instead."
expect_contains "auto-detect: the fallback still installs the release channel" \
  "${nominor_output}" "(release channel)"

rm -f "${QUARTO_SHIM}/quarto"

# The reload hint has to name a command that loads the block just written.
# `exec bash -l` does not: a login bash reads ~/.bash_profile, ~/.bash_login,
# or ~/.profile, and never falls back to the ~/.bashrc this installer writes
# to. On macOS none of those exist by default and the terminal opens login
# shells, so the advice used to send people to a shell with no completions in
# it and nothing on screen to explain why.
RELOAD_HOME="$(scenario_home reload-bash)"
reload_output="$(scenario_run "${RELOAD_HOME}" --shell bash)"
expect_contains "reload: bash is told to start a shell that reads .bashrc" \
  "${reload_output}" "exec bash"
expect_missing "reload: bash is not sent to a login shell" "${reload_output}" "exec bash -l"
expect_contains "reload: a home with no login profile is warned" \
  "${reload_output}" ".bash_profile"

# A login profile that reaches ~/.bashrc needs no warning: the block it loads
# is the one just written.
PROFILE_HOME="$(scenario_home reload-bash-profile)"
printf '[ -r ~/.bashrc ] && . ~/.bashrc\n' >"${PROFILE_HOME}/.bash_profile"
profile_output="$(scenario_run "${PROFILE_HOME}" --shell bash)"
expect_contains "reload: a home with a wired login profile still gets the hint" \
  "${profile_output}" "exec bash"
expect_missing "reload: a wired login profile is not warned" \
  "${profile_output}" "will not read"

# A login profile that never mentions .bashrc is the same dead end as having
# none: a macOS ~/.bash_profile holding nothing but PATH exports is at least
# as common as no file at all, and existence alone proved nothing.
INERT_HOME="$(scenario_home reload-bash-inert)"
printf 'export EDITOR=vi\n' >"${INERT_HOME}/.bash_profile"
inert_output="$(scenario_run "${INERT_HOME}" --shell bash)"
expect_contains "reload: a login profile that skips .bashrc is warned" \
  "${inert_output}" "does not mention ~/.bashrc"
expect_contains "reload: the inert profile is named" \
  "${inert_output}" "Your ~/.bash_profile"

# bash reads only the first of the three login files it finds, so a .profile
# that sources .bashrc is dead code under a .bash_profile that does not.
SHADOW_HOME="$(scenario_home reload-bash-shadow)"
printf 'export EDITOR=vi\n' >"${SHADOW_HOME}/.bash_profile"
printf '[ -r ~/.bashrc ] && . ~/.bashrc\n' >"${SHADOW_HOME}/.profile"
shadow_output="$(scenario_run "${SHADOW_HOME}" --shell bash)"
expect_contains "reload: a wired .profile shadowed by .bash_profile still warns" \
  "${shadow_output}" "does not mention ~/.bashrc"

# zsh reads .zshrc for every interactive shell, login or not, so it needs
# neither the -l nor the warning. fish autoloads its completions directory and
# needs even less.
ZRELOAD_HOME="$(scenario_home reload-zsh)"
zreload_output="$(scenario_run "${ZRELOAD_HOME}" --shell zsh)"
expect_contains "reload: zsh is told to start a new shell" "${zreload_output}" "exec zsh"
expect_missing "reload: zsh is not sent to a login shell" "${zreload_output}" "exec zsh -l"
expect_missing "reload: zsh is never warned about a login profile" \
  "${zreload_output}" ".bash_profile"
FRELOAD_HOME="$(scenario_home reload-fish)"
freload_output="$(scenario_run "${FRELOAD_HOME}" --shell fish)"
expect_contains "reload: fish is told to start a new shell" "${freload_output}" "exec fish"
expect_missing "reload: fish is not sent to a login shell" "${freload_output}" "exec fish -l"

# An install maintains one shell, the one $SHELL named. When another shell on
# the machine holds a completion from a different Quarto or a different
# channel, saying nothing leaves the user pressing Tab in that other shell,
# seeing the old command set, with a successful install on screen and no way
# to connect the two.
OTHER_HOME="$(scenario_home other-stale)"
mkdir -p "${OTHER_HOME}/.zfunc"
printf '%s\n%s\n%s\n' \
  "#compdef quarto" \
  "# Quarto CLI completions, generated by quarto-completions." \
  "# Quarto 0.1.0 (pre-release channel)." \
  >"${OTHER_HOME}/.zfunc/_quarto"
other_output="$(scenario_run "${OTHER_HOME}" --shell bash)"
expect_contains "other shells: a stale zsh install is named" \
  "${other_output}" "${OTHER_HOME}/.zfunc/_quarto"
expect_contains "other shells: the stale file's own stamp is reported" \
  "${other_output}" "0.1.0"
expect_contains "other shells: the command that updates it is given" \
  "${other_output}" "--shell zsh"

# Two other shells holding stale files get a note each: the break that stops
# reading locations once a shell has been reported must not stop the shells
# after it from being looked at.
BOTH_HOME="$(scenario_home other-both)"
mkdir -p "${BOTH_HOME}/.zfunc" "${BOTH_HOME}/.config/fish/completions"
printf '#compdef quarto\n# Quarto 0.1.0 (release channel).\n' \
  >"${BOTH_HOME}/.zfunc/_quarto"
printf '# Quarto 0.2.0 (pre-release channel).\n' \
  >"${BOTH_HOME}/.config/fish/completions/quarto.fish"
both_output="$(scenario_run "${BOTH_HOME}" --shell bash)"
expect_contains "other shells: the first stale shell is named" \
  "${both_output}" "--shell zsh"
expect_contains "other shells: the second stale shell is named too" \
  "${both_output}" "--shell fish"

# A matching install is not worth a line: it is already the file this run
# would write.
MATCHED_HOME="$(scenario_home other-matched)"
scenario_run "${MATCHED_HOME}" --shell zsh >/dev/null
matched_output="$(scenario_run "${MATCHED_HOME}" --shell bash)"
expect_missing "other shells: a matching install says nothing" \
  "${matched_output}" "--shell zsh"

# Nor is a shell with no install at all: this reports on what is there, and
# never talks anyone into installing a shell they do not use.
NONE_HOME="$(scenario_home other-none)"
none_output="$(scenario_run "${NONE_HOME}" --shell bash)"
expect_missing "other shells: a shell with no install says nothing" \
  "${none_output}" "also has completions"

# A file this installer did not write carries no stamp to compare, and
# guessing at one would mean reporting a hand-written completion as stale on
# every run.
UNSTAMPED_HOME="$(scenario_home other-unstamped)"
mkdir -p "${UNSTAMPED_HOME}/.zfunc"
printf '#compdef quarto\n# hand written\n' >"${UNSTAMPED_HOME}/.zfunc/_quarto"
unstamped_output="$(scenario_run "${UNSTAMPED_HOME}" --shell bash)"
expect_missing "other shells: an unstamped file says nothing" \
  "${unstamped_output}" "also has completions"

# A file nobody can read carries no stamp anyone can compare, and reaching for
# one must not take down an install that has otherwise worked. Homebrew's
# prefix and a system package both leave files behind that the user may not be
# able to read, and this advice runs on the last line of a successful install.
UNREADABLE_HOME="$(scenario_home other-unreadable)"
mkdir -p "${UNREADABLE_HOME}/.zfunc"
printf '#compdef quarto\n# Quarto 0.1.0 (release channel).\n' \
  >"${UNREADABLE_HOME}/.zfunc/_quarto"
chmod 000 "${UNREADABLE_HOME}/.zfunc/_quarto"
if unreadable_output="$(scenario_run "${UNREADABLE_HOME}" --shell bash 2>&1)"; then
  pass "other shells: an unreadable file does not fail the install"
else
  fail "other shells: an unreadable file does not fail the install" "${unreadable_output}"
fi
expect_file "the install still lands beside an unreadable file" \
  "${UNREADABLE_HOME}/.local/share/quarto-completions/quarto.bash"
chmod 600 "${UNREADABLE_HOME}/.zfunc/_quarto"

# Uninstalling maintains nothing and installs nothing, so neither note belongs
# in its output.
QUIET_HOME="$(scenario_home other-uninstall)"
mkdir -p "${QUIET_HOME}/.zfunc"
printf '#compdef quarto\n# Quarto 0.1.0 (release channel).\n' >"${QUIET_HOME}/.zfunc/_quarto"
scenario_run "${QUIET_HOME}" --shell bash >/dev/null
quiet_output="$(scenario_run "${QUIET_HOME}" --shell bash --uninstall)"
expect_missing "uninstall: no other-shell note" "${quiet_output}" "also has completions"
expect_missing "uninstall: no reload advice" "${quiet_output}" "exec bash"

summary
