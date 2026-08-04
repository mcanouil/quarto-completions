#!/usr/bin/env bash
#
# Installs Quarto CLI shell completions for bash, zsh, or fish.
#
#     curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash
#
# Everything is written under the user's home directory, save for zsh on a
# machine with Homebrew, where the completion goes in the prefix's own
# site-functions directory when that is already writable. Nothing needs root,
# nothing is written with sudo, and nothing outside the paths reported by
# --dry-run is touched.

set -euo pipefail

BASE_URL="${QUARTO_COMPLETIONS_BASE_URL:-https://m.canouil.dev/quarto-completions}"
# Left empty rather than defaulted here: resolve_channel tells an unset
# channel from an explicit one, which is what lets it pick 'dev' only when
# nothing named a channel at all.
CHANNEL="${QUARTO_COMPLETIONS_CHANNEL:-}"
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
  --channel <stable|prerelease|dev>
                            Quarto release channel (default: stable, or dev
                            when the quarto on PATH reports version 99.9.9).
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
}

# The quarto on PATH's reported version, or empty when there is none or it
# does not answer. Read once and shared by the dev auto-detect below and the
# version advisory in do_install, so an install spawns quarto at most once.
LOCAL_QUARTO_VERSION=""
detect_local_quarto_version() {
  if command -v quarto >/dev/null 2>&1; then
    # head -n 1: a wrapper or a build with extra banner output on stdout must
    # not sink the comparison below by trailing text the real version lacks.
    LOCAL_QUARTO_VERSION="$(quarto --version 2>/dev/null | head -n 1)"
  fi
}

# Fills in a channel nothing named explicitly, then validates whatever the
# result is. Only a quarto on PATH reporting exactly '99.9.9' selects 'dev':
# that is the version Quarto's own kLocalDevelopment constant reports for an
# unreleased source build, the one build whose hidden commands the dev
# channel completes. Uninstalling never reads CHANNEL, so an unset one there
# is left at a placeholder rather than spent starting quarto for nothing.
resolve_channel() {
  if [ -z "${CHANNEL}" ] && [ "${ACTION}" = "uninstall" ]; then
    CHANNEL="stable"
  fi
  if [ -z "${CHANNEL}" ]; then
    if [ "${LOCAL_QUARTO_VERSION}" = "99.9.9" ]; then
      CHANNEL="dev"
    else
      CHANNEL="stable"
    fi
  fi

  case "${CHANNEL}" in
    stable | prerelease | dev) ;;
    *) fail "channel must be 'stable', 'prerelease', or 'dev', got '${CHANNEL}'" ;;
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

# The "<major>.<minor>" prefix of a version string, or empty when it does not
# start with one.
version_major_minor() {
  printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1.\2/p'
}

# True when major.minor $1 is newer than major.minor $2. Plain integer
# comparison rather than `sort -V`, which macOS's BSD sort does not have.
version_newer() {
  local major1="${1%%.*}" minor1="${1#*.}" major2="${2%%.*}" minor2="${2#*.}"
  if [ "${major1}" -ne "${major2}" ]; then
    [ "${major1}" -gt "${major2}" ]
  else
    [ "${minor1}" -gt "${minor2}" ]
  fi
}

# The one advisory line for a Quarto that does not match what these
# completions were generated from, or nothing when there is nothing useful to
# say. Never fails the install; a mismatch is only ever a note.
version_advice() {
  # $1: manifest quartoVersion, $2: local quarto version (may be empty), $3: channel
  local manifest_mm local_mm
  [ -n "$2" ] || return 0
  [ "$2" != "99.9.9" ] || return 0
  [ "$3" != "dev" ] || return 0
  manifest_mm="$(version_major_minor "$1")"
  local_mm="$(version_major_minor "$2")"
  [ -n "${manifest_mm}" ] && [ -n "${local_mm}" ] || return 0
  [ "${manifest_mm}" != "${local_mm}" ] || return 0

  if version_newer "${local_mm}" "${manifest_mm}"; then
    if [ "$3" = "stable" ]; then
      log "Your Quarto is $2, newer than these completions. Run again with --channel prerelease if you are on a Quarto prerelease."
    else
      log "Your Quarto is $2, newer than these completions; flags added since then are not completed yet."
    fi
  else
    log "Your Quarto is $2, older than these completions; some completions may name flags your Quarto does not have."
  fi
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

# Oh My Zsh's custom directory, which is both written to and, once stale,
# removed.
#
# $ZSH is exported by Oh My Zsh's stock .zshrc and $ZSH_CUSTOM may be, so both
# survive into a child process whose HOME is something else: `sudo -E`, a
# container, or a plain `HOME=/tmp/x bash install.sh`. Following them out of
# $HOME would mean deleting another home's completions, and would break the
# promise at the top of this file. They are honoured, because a relocated
# Oh My Zsh is worth supporting, but only when they point inside $HOME.
omz_custom() {
  local candidate="${ZSH_CUSTOM:-${ZSH:+${ZSH}/custom}}"
  if [ -n "${candidate}" ] && [ -n "${HOME:-}" ]; then
    case "${candidate}" in
      "${HOME}"/*)
        echo "${candidate}"
        return
        ;;
    esac
  fi
  echo "${HOME}/.oh-my-zsh/custom"
}

# Homebrew's completion directory, when this machine has one, and nothing when
# it does not.
#
# Homebrew's own shell setup puts this on fpath, so a file written here needs no
# managed block. `brew --prefix` is not run to find it: a `curl | bash` pipe
# frequently has no brew on PATH, and starting it costs a second for an answer
# three directory tests give. $HOMEBREW_PREFIX is authoritative when set, since
# a machine that has moved its prefix has also exported this.
brew_site_functions() {
  local prefix
  if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    if [ -d "${HOMEBREW_PREFIX}/share/zsh/site-functions" ]; then
      printf '%s' "${HOMEBREW_PREFIX}/share/zsh/site-functions"
    fi
    return 0
  fi
  for prefix in /opt/homebrew /usr/local; do
    if [ -d "${prefix}/share/zsh/site-functions" ]; then
      printf '%s' "${prefix}/share/zsh/site-functions"
      return 0
    fi
  done
}

# What the given location needs beyond the file itself, as RC_FILE and RC_BODY.
#
# Keyed on the location rather than on the machine's layout, because the two can
# disagree: an install already in ~/.zfunc is kept there even once Oh My Zsh
# appears, and it still needs its fpath line.
configure_target() {
  # $1: the completion file
  local directory omz brew
  TARGET_FILE="$1"
  RC_FILE=""
  RC_BODY=""
  directory="$(dirname "$1")"

  case "${TARGET_SHELL}" in
    bash)
      # bash-completion loads its own directory lazily. Anywhere else has to be
      # sourced.
      if [ "${directory}" != "$(data_home)/bash-completion/completions" ]; then
        RC_FILE="${HOME}/.bashrc"
        RC_BODY="[ -r \"$1\" ] && . \"$1\""
      fi
      ;;
    zsh)
      # Oh My Zsh puts $ZSH_CUSTOM/completions on fpath and calls compinit
      # itself, both before .zshrc reaches anything appended to it, so a file
      # there is enough and a managed block would only run too late. Homebrew's
      # directory is on fpath by the same argument.
      omz="$(omz_custom)/completions"
      brew="$(brew_site_functions)"
      if [ "${directory}" = "${omz}" ]; then
        return 0
      fi
      if [ -n "${brew}" ] && [ "${directory}" = "${brew}" ]; then
        return 0
      fi
      RC_FILE="${HOME}/.zshrc"
      # `compinit -i`, not `-C`. `-C` omits the check for new completion
      # functions and reuses the dump when one exists, and one always does
      # here: this block is appended below whatever compinit the user already
      # calls, so `_quarto` would never be picked up. `-i` keeps that check and
      # only skips the warning about insecure directories, which the user's own
      # call has already reported if there was anything to report.
      RC_BODY="fpath=(\"${directory}\" \$fpath)
autoload -Uz compinit && compinit -i"
      ;;
    fish)
      # fish autoloads this directory, so there is nothing to add to config.
      ;;
  esac
}

# Where a first install goes, given what this machine has installed.
default_location() {
  local omz brew
  case "${TARGET_SHELL}" in
    bash)
      if [ -d "$(data_home)/bash-completion/completions" ]; then
        printf '%s' "$(data_home)/bash-completion/completions/quarto"
      else
        printf '%s' "$(data_home)/quarto-completions/quarto.bash"
      fi
      ;;
    zsh)
      omz="$(omz_custom)"
      if [ -d "${omz}" ]; then
        printf '%s' "${omz}/completions/_quarto"
        return 0
      fi
      # Writability is asked of Homebrew's directory and of nothing else: it is
      # the one candidate outside the user's home, and a prefix installed by
      # another user must not turn an install into a permission error.
      brew="$(brew_site_functions)"
      if [ -n "${brew}" ] && [ -w "${brew}" ]; then
        printf '%s' "${brew}/_quarto"
        return 0
      fi
      printf '%s' "${HOME}/.zfunc/_quarto"
      ;;
    fish)
      printf '%s' "$(config_home)/fish/completions/quarto.fish"
      ;;
  esac
}

# Every location this installer has ever written for a shell, and the ones a
# reader of the documentation would have written by hand, in the order an
# install prefers them.
#
# Two jobs. Re-running clears out whatever an earlier run left behind, or the
# old copy is silently kept up to date by nothing; and an install takes the
# first of these that already exists, so a location chosen deliberately is not
# moved by installing Oh My Zsh or Homebrew afterwards.
known_targets_for() {
  local brew
  case "$1" in
    bash)
      printf '%s\n' \
        "$(data_home)/bash-completion/completions/quarto" \
        "$(data_home)/quarto-completions/quarto.bash"
      ;;
    zsh)
      brew="$(brew_site_functions)"
      printf '%s\n' "$(omz_custom)/completions/_quarto"
      if [ -n "${brew}" ]; then
        printf '%s\n' "${brew}/_quarto"
      fi
      # ~/.zfunc is where an install goes when nothing else applies; the XDG
      # directory is where this installer and the manual instructions on the
      # website pointed before, and is listed so that a file left there is
      # found and swept rather than kept to shadow this one.
      printf '%s\n' \
        "${HOME}/.zfunc/_quarto" \
        "$(data_home)/zsh/site-functions/_quarto"
      ;;
    fish)
      printf '%s\n' "$(config_home)/fish/completions/quarto.fish"
      ;;
  esac
}

# Places a file is only ever cleaned out of, never written to.
#
# Somewhere an earlier version of this installer, or of the instructions on the
# website, put the script. A file found there is swept so it cannot shadow the
# one being maintained, and it is never chosen: choosing it would keep the
# install on the very layout this is moving it off.
sweep_only_for() {
  case "$1" in
    zsh) printf '%s\n' "$(data_home)/zsh/site-functions/_quarto" ;;
  esac
}

sweep_only() {
  # $1: location
  local location
  while IFS= read -r location; do
    if [ -n "${location}" ] && [ "${location}" = "$1" ]; then
      return 0
    fi
  done <<EOF
$(sweep_only_for "${TARGET_SHELL}")
EOF
  return 1
}

# The first location that already holds a file and can be written to again, and
# nothing when none does. Writability is asked of the directory, which is what
# replacing the file needs: a copy in a prefix that has since become someone
# else's would otherwise be chosen and then die on the mv, after the download.
existing_location() {
  local location
  while IFS= read -r location; do
    if [ -n "${location}" ] && [ -f "${location}" ] && [ -w "$(dirname "${location}")" ] &&
      ! sweep_only "${location}"; then
      printf '%s' "${location}"
      return 0
    fi
  done <<EOF
$(known_targets_for "${TARGET_SHELL}")
EOF
}

# Where the completion file belongs, and which rc file (if any) needs a line
# added so the shell picks it up.
resolve_target() {
  local existing
  existing="$(existing_location)"
  if [ -n "${existing}" ]; then
    TARGET_EXISTING=1
    configure_target "${existing}"
    return 0
  fi
  TARGET_EXISTING=0
  configure_target "$(default_location)"
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
    # A copy that cannot be removed is reported rather than fatal. One of the
    # places looked in is Homebrew's prefix, which is outside the home
    # directory and may belong to another user or to a package manager, and a
    # file there is not reason enough to fail an install that has otherwise
    # worked. Nothing is ever removed with sudo.
    if rm -f "${location}" 2>/dev/null; then
      log "Removed ${location}"
    else
      log "Could not remove ${location}: no permission. Remove it yourself, or"
      log "it may be found before the one that is kept up to date."
    fi
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
  # Written back through the existing file rather than moved over it: an rc
  # file is often a symlink into a dotfiles checkout, and mv would replace the
  # link with a plain file carrying mktemp's 0600 mode. The redirect names the
  # file on failure; set -e alone would stop with a bare permission error.
  if ! cat "${temporary}" >"$1"; then
    rm -f "${temporary}"
    fail "could not write $1: fix its permissions and re-run"
  fi
  rm -f "${temporary}"
}

write_rc_block() {
  # $1: rc file, $2: body
  remove_rc_block "$1"
  mkdir -p "$(dirname "$1")"
  # The same message as the rewrite in remove_rc_block: a first install into
  # an existing rc file without a block reaches this append directly.
  {
    printf '%s\n' "${BLOCK_START}"
    printf '%s\n' "$2"
    printf '%s\n' "${BLOCK_END}"
  } >>"$1" || fail "could not write $1: fix its permissions and re-run"
}

do_install() {
  local name url manifest_url manifest expected actual
  name="$(script_name_for "${TARGET_SHELL}")"
  url="${BASE_URL}/completions/${CHANNEL}/${name}"
  manifest_url="${BASE_URL}/completions/${CHANNEL}/manifest.json"

  if [ "${DRY_RUN}" = "1" ]; then
    log "Would download ${url}"
    if [ "${TARGET_EXISTING}" = "1" ]; then
      log "Would update   ${TARGET_FILE} (existing install)"
    else
      log "Would write    ${TARGET_FILE}"
    fi
    if [ -n "${RC_FILE}" ]; then
      log "Would update   ${RC_FILE} (managed block)"
    fi
    report_stale "Would remove  " "Would clean   " "${TARGET_FILE}" "${RC_FILE}"
    return 0
  fi

  if [ "${TARGET_EXISTING}" = "1" ]; then
    log "Updating existing install at ${TARGET_FILE}"
  fi

  TEMPORARY="$(mktemp -d)"

  fetch "${manifest_url}" "${TEMPORARY}/manifest.json"
  expected="$(manifest_sha "${TEMPORARY}/manifest.json" "${name}")"
  [ -n "${expected}" ] || fail "no checksum for ${name} in ${manifest_url}"

  # The manifest alone answers whether there is anything to download: a file
  # already matching the published checksum is the file that would be written.
  # Saying so, and leaving it alone, keeps a re-run over an unchanged release
  # quiet. The rc block and the stale sweep still run below, since the layout
  # can have moved even when the script has not.
  if [ -f "${TARGET_FILE}" ] && [ "$(sha256_of "${TARGET_FILE}")" = "${expected}" ]; then
    log "Already current ${TARGET_FILE}"
  else
    fetch "${url}" "${TEMPORARY}/${name}"
    actual="$(sha256_of "${TEMPORARY}/${name}")"
    if [ "${expected}" != "${actual}" ]; then
      fail "checksum mismatch for ${name}: expected ${expected}, got ${actual}"
    fi

    mkdir -p "$(dirname "${TARGET_FILE}")"
    mv "${TEMPORARY}/${name}" "${TARGET_FILE}"
    log "Installed ${TARGET_FILE}"
  fi

  if [ -n "${RC_FILE}" ]; then
    write_rc_block "${RC_FILE}" "${RC_BODY}"
    log "Updated ${RC_FILE}"
  fi

  remove_stale "${TARGET_FILE}" "${RC_FILE}"

  manifest="$(sed -n 's/.*"quartoVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${TEMPORARY}/manifest.json" | head -n 1)"
  log ""
  log "Quarto ${manifest} completions for ${TARGET_SHELL} (${CHANNEL} channel)."
  version_advice "${manifest}" "${LOCAL_QUARTO_VERSION}" "${CHANNEL}"
  log "Start a new shell, or run: exec ${TARGET_SHELL} -l"
}

# Everything an uninstall would touch: the scripts, and the rc file when it
# still holds a managed block. Both halves count, or a home whose script is
# already gone but whose block is not reports "Nothing to remove" immediately
# after saying it cleaned the rc file.
uninstall_residue() {
  printf '%s%s' "$(stale_locations "")" "$(stale_rc "")"
}

do_uninstall() {
  # Nothing is kept, so every location and the rc block go, whichever layout
  # this machine happens to resolve to now.
  local residue
  residue="$(uninstall_residue)"

  if [ "${DRY_RUN}" = "1" ]; then
    # Saying nothing at all would read as a broken script, and --dry-run is the
    # first thing the troubleshooting page asks people to run.
    if [ -z "${residue}" ]; then
      log "Nothing to remove for ${TARGET_SHELL}"
    else
      report_stale "Would remove" "Would clean " "" ""
    fi
    return 0
  fi

  remove_stale "" ""
  if [ -z "${residue}" ]; then
    log "Nothing to remove for ${TARGET_SHELL}"
  fi
}

main() {
  parse_args "$@"
  if [ "${ACTION}" = "install" ]; then
    detect_local_quarto_version
  fi
  resolve_channel
  detect_shell

  TARGET_FILE=""
  RC_FILE=""
  RC_BODY=""
  TARGET_EXISTING=0
  resolve_target

  case "${ACTION}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
