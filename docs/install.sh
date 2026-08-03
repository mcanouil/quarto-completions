#!/usr/bin/env bash
#
# Installs Quarto CLI shell completions for bash, zsh, or fish.
#
#     curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash
#
# Everything is written under the user's home directory. Nothing needs root,
# and nothing outside the paths reported by --dry-run is touched.

set -euo pipefail

BASE_URL="${QUARTO_COMPLETIONS_BASE_URL:-https://m.canouil.dev/quarto-completions}"
CHANNEL="${QUARTO_COMPLETIONS_CHANNEL:-stable}"
TARGET_SHELL="${QUARTO_COMPLETIONS_SHELL:-}"
ACTION="install"
DRY_RUN=0
# Set once the download directory exists, and read by the EXIT trap.
TEMPORARY=""

cleanup() {
  # Returning non-zero from an EXIT trap would rewrite the exit status.
  if [ -n "${TEMPORARY}" ]; then
    rm -rf "${TEMPORARY}"
  fi
}
trap cleanup EXIT

BLOCK_START="# >>> quarto completions >>>"
BLOCK_END="# <<< quarto completions <<<"

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --shell <bash|zsh|fish>   Shell to install for (default: detected from $SHELL).
  --channel <stable|prerelease>
                            Quarto release channel (default: stable).
  --uninstall               Remove the completions and the managed block.
  --dry-run                 Report every path that would change, then exit.
  --base-url <url>          Where to fetch from (default: the published site).
  -h, --help                Show this help.

Environment equivalents, for the piped `curl | bash` form:
  QUARTO_COMPLETIONS_SHELL, QUARTO_COMPLETIONS_CHANNEL,
  QUARTO_COMPLETIONS_BASE_URL, QUARTO_COMPLETIONS_UNINSTALL=1
EOF
}

log() { printf '%s\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Fails with a message when an option that needs a value was given none.
# Without this, `shift 2` on a lone flag ends the script silently.
require_value() {
  # $1: option name, $2: remaining argument count
  [ "$2" -ge 2 ] || fail "option '$1' needs a value (try --help)"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --shell)
        require_value "$1" "$#"
        TARGET_SHELL="$2"
        shift 2
        ;;
      --channel)
        require_value "$1" "$#"
        CHANNEL="$2"
        shift 2
        ;;
      --base-url)
        require_value "$1" "$#"
        BASE_URL="$2"
        shift 2
        ;;
      --uninstall)
        ACTION="uninstall"
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) fail "unknown option '$1' (try --help)" ;;
    esac
  done

  if [ "${QUARTO_COMPLETIONS_UNINSTALL:-0}" = "1" ]; then
    ACTION="uninstall"
  fi

  case "${CHANNEL}" in
    stable | prerelease) ;;
    *) fail "channel must be 'stable' or 'prerelease', got '${CHANNEL}'" ;;
  esac
}

detect_shell() {
  if [ -n "${TARGET_SHELL}" ]; then
    return
  fi
  if [ -n "${SHELL:-}" ]; then
    TARGET_SHELL="$(basename "${SHELL}")"
  fi
  case "${TARGET_SHELL}" in
    bash | zsh | fish) ;;
    *)
      fail "could not detect a supported shell (got '${TARGET_SHELL:-none}'); pass --shell bash|zsh|fish"
      ;;
  esac
}

fetch() {
  # $1: url, $2: destination
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    fail "neither curl nor wget is available"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "neither sha256sum nor shasum is available"
  fi
}

# Reads one checksum out of manifest.json without requiring jq. The file name
# is escaped because `.` would otherwise match any character.
manifest_sha() {
  # $1: manifest path, $2: file name
  local key
  key="$(printf '%s' "$2" | sed 's/[.[\*^$]/\\&/g')"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([0-9a-f]\{64\}\)\".*/\1/p" "$1" | head -n 1
}

script_name_for() {
  case "$1" in
    bash) echo "quarto.bash" ;;
    zsh) echo "_quarto" ;;
    fish) echo "quarto.fish" ;;
  esac
}

data_home() { echo "${XDG_DATA_HOME:-${HOME}/.local/share}"; }
config_home() { echo "${XDG_CONFIG_HOME:-${HOME}/.config}"; }

# Oh My Zsh's custom directory. It sets $ZSH and $ZSH_CUSTOM inside interactive
# zsh and does not export them, so a `curl | bash` run almost always falls
# through to the default; honouring them anyway costs nothing and covers a
# relocated install.
omz_custom() { echo "${ZSH_CUSTOM:-${ZSH:-${HOME}/.oh-my-zsh}/custom}"; }

# Where the completion file belongs, and which rc file (if any) needs a line
# added so the shell picks it up.
resolve_target() {
  case "${TARGET_SHELL}" in
    bash)
      local bash_completion_dir
      bash_completion_dir="$(data_home)/bash-completion/completions"
      if [ -d "${bash_completion_dir}" ]; then
        # bash-completion loads this directory lazily; no rc edit needed.
        TARGET_FILE="${bash_completion_dir}/quarto"
        RC_FILE=""
      else
        TARGET_FILE="$(data_home)/quarto-completions/quarto.bash"
        RC_FILE="${HOME}/.bashrc"
        RC_BODY="[ -r \"${TARGET_FILE}\" ] && . \"${TARGET_FILE}\""
      fi
      ;;
    zsh)
      local omz site_functions
      omz="$(omz_custom)"
      if [ -d "${omz}" ]; then
        # Oh My Zsh puts $ZSH_CUSTOM/completions on fpath and calls compinit
        # itself, both before .zshrc reaches anything appended to it, so the
        # file on its own is enough and a managed block would only run too late.
        TARGET_FILE="${omz}/completions/_quarto"
        RC_FILE=""
        return
      fi
      site_functions="$(data_home)/zsh/site-functions"
      TARGET_FILE="${site_functions}/_quarto"
      RC_FILE="${HOME}/.zshrc"
      # `compinit -i`, not `-C`. `-C` omits the check for new completion
      # functions and reuses the dump when one exists, and one always does
      # here: this block is appended below whatever compinit the user already
      # calls, so `_quarto` would never be picked up. `-i` keeps that check and
      # only skips the warning about insecure directories, which the user's own
      # call has already reported if there was anything to report.
      RC_BODY="fpath=(\"${site_functions}\" \$fpath)
autoload -Uz compinit && compinit -i"
      ;;
    fish)
      # fish autoloads this directory, so there is nothing to add to config.
      TARGET_FILE="$(config_home)/fish/completions/quarto.fish"
      RC_FILE=""
      ;;
  esac
}

# Every location this installer has ever written for a shell. Which one
# `resolve_target` picks depends on what is installed on the machine, and that
# changes: adding bash-completion, or Oh My Zsh, moves the answer. Re-running
# has to clear out whatever an earlier run left behind, or the old copy is
# silently kept up to date by nothing.
known_targets_for() {
  case "$1" in
    bash)
      printf '%s\n' \
        "$(data_home)/bash-completion/completions/quarto" \
        "$(data_home)/quarto-completions/quarto.bash"
      ;;
    zsh)
      printf '%s\n' \
        "$(omz_custom)/completions/_quarto" \
        "$(data_home)/zsh/site-functions/_quarto"
      ;;
    fish)
      printf '%s\n' "$(config_home)/fish/completions/quarto.fish"
      ;;
  esac
}

# The rc file a shell would ever carry a managed block in, whether or not the
# layout resolved this time wants one.
rc_file_for() {
  case "$1" in
    bash) printf '%s\n' "${HOME}/.bashrc" ;;
    zsh) printf '%s\n' "${HOME}/.zshrc" ;;
  esac
}

# Locations that exist and are not the one being kept. Pass an empty argument to
# keep none of them, which is what uninstalling wants.
stale_locations() {
  # $1: location to keep, or empty
  local location
  known_targets_for "${TARGET_SHELL}" | while IFS= read -r location; do
    if [ -z "${location}" ] || [ "${location}" = "$1" ]; then
      continue
    fi
    if [ -f "${location}" ]; then
      printf '%s\n' "${location}"
    fi
  done
}

# The rc file, when it holds a managed block that is not wanted any more.
stale_rc() {
  # $1: rc file the resolved layout will write to, or empty
  local rc
  rc="$(rc_file_for "${TARGET_SHELL}")"
  if [ -n "${rc}" ] && [ "${rc}" != "$1" ] && rc_block_present "${rc}"; then
    printf '%s\n' "${rc}"
  fi
}

# The same two lists as remove_stale, printed rather than acted on, so that
# --dry-run reports every path it would touch and not only the one it writes.
report_stale() {
  # $1: file prefix, $2: rc prefix, $3: location to keep, $4: rc to keep
  local location rc
  while IFS= read -r location; do
    [ -n "${location}" ] || continue
    log "$1 ${location}"
  done <<EOF
$(stale_locations "$3")
EOF

  while IFS= read -r rc; do
    [ -n "${rc}" ] || continue
    log "$2 ${rc} (managed block)"
  done <<EOF
$(stale_rc "$4")
EOF
}

remove_stale() {
  # $1: location to keep, or empty; $2: rc file to keep, or empty
  local location rc
  while IFS= read -r location; do
    [ -n "${location}" ] || continue
    rm -f "${location}"
    log "Removed ${location}"
  done <<EOF
$(stale_locations "$1")
EOF

  while IFS= read -r rc; do
    [ -n "${rc}" ] || continue
    remove_rc_block "${rc}"
    log "Cleaned ${rc}"
  done <<EOF
$(stale_rc "$2")
EOF
}

rc_block_present() {
  [ -f "$1" ] && grep -qF "${BLOCK_START}" "$1"
}

remove_rc_block() {
  # $1: rc file
  [ -f "$1" ] || return 0
  rc_block_present "$1" || return 0
  local temporary
  temporary="$(mktemp)"
  sed "/^${BLOCK_START}\$/,/^${BLOCK_END}\$/d" "$1" >"${temporary}"
  mv "${temporary}" "$1"
}

write_rc_block() {
  # $1: rc file, $2: body
  remove_rc_block "$1"
  mkdir -p "$(dirname "$1")"
  {
    printf '%s\n' "${BLOCK_START}"
    printf '%s\n' "$2"
    printf '%s\n' "${BLOCK_END}"
  } >>"$1"
}

do_install() {
  local name url manifest_url manifest expected actual
  name="$(script_name_for "${TARGET_SHELL}")"
  url="${BASE_URL}/completions/${CHANNEL}/${name}"
  manifest_url="${BASE_URL}/completions/${CHANNEL}/manifest.json"

  if [ "${DRY_RUN}" = "1" ]; then
    log "Would download ${url}"
    log "Would write    ${TARGET_FILE}"
    if [ -n "${RC_FILE}" ]; then
      log "Would update   ${RC_FILE} (managed block)"
    fi
    report_stale "Would remove  " "Would clean   " "${TARGET_FILE}" "${RC_FILE}"
    return 0
  fi

  TEMPORARY="$(mktemp -d)"

  fetch "${manifest_url}" "${TEMPORARY}/manifest.json"
  fetch "${url}" "${TEMPORARY}/${name}"

  expected="$(manifest_sha "${TEMPORARY}/manifest.json" "${name}")"
  [ -n "${expected}" ] || fail "no checksum for ${name} in ${manifest_url}"
  actual="$(sha256_of "${TEMPORARY}/${name}")"
  if [ "${expected}" != "${actual}" ]; then
    fail "checksum mismatch for ${name}: expected ${expected}, got ${actual}"
  fi

  mkdir -p "$(dirname "${TARGET_FILE}")"
  mv "${TEMPORARY}/${name}" "${TARGET_FILE}"
  log "Installed ${TARGET_FILE}"

  if [ -n "${RC_FILE}" ]; then
    write_rc_block "${RC_FILE}" "${RC_BODY}"
    log "Updated ${RC_FILE}"
  fi

  remove_stale "${TARGET_FILE}" "${RC_FILE}"

  manifest="$(sed -n 's/.*"quartoVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${TEMPORARY}/manifest.json" | head -n 1)"
  log ""
  log "Quarto ${manifest} completions for ${TARGET_SHELL} (${CHANNEL} channel)."
  log "Start a new shell, or run: exec ${TARGET_SHELL} -l"
}

do_uninstall() {
  # Nothing is kept, so every location and the rc block go, whichever layout
  # this machine happens to resolve to now.
  if [ "${DRY_RUN}" = "1" ]; then
    report_stale "Would remove" "Would clean " "" ""
    return 0
  fi

  local found
  found="$(stale_locations "")"
  remove_stale "" ""
  if [ -z "${found}" ]; then
    log "Nothing to remove for ${TARGET_SHELL}"
  fi
}

main() {
  parse_args "$@"
  detect_shell

  TARGET_FILE=""
  RC_FILE=""
  RC_BODY=""
  resolve_target

  case "${ACTION}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
