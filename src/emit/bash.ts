/**
 * Emits a self-contained bash completion script.
 *
 * The script never runs `quarto`: every candidate is baked in. It targets bash
 * 3.2, which is what macOS ships, so no associative arrays and no `${var^^}`.
 *
 * Words typed so far are walked once, which resolves three things at the same
 * time: the command path, how many positionals have been supplied, and which
 * words were consumed as flag values rather than positionals.
 */

import type { ArgSpec, CommandSpec, Spec } from "../spec.ts";
import { commandName, nodeId, optionFlags } from "../spec.ts";
import {
  banner,
  flags,
  nodes,
  positionals,
  trailingIsVariadic,
  valuedFlags,
  valuedOptions,
} from "./common.ts";

export function emitBash(spec: Spec): string {
  const all = nodes(spec);
  const ids = all.map((command) => nodeId(command.path)).join(" ");

  return `#!/usr/bin/env bash
${banner(spec, "#")}

_quarto_nodes="${ids}"

_quarto_words() {
  # shellcheck disable=SC2207
  COMPREPLY+=( $(compgen -W "$1" -- "$cur") )
}

_quarto_files() {
  local pattern="$1" enabled=0
  if [ -n "$pattern" ]; then
    # shopt -q is a builtin; reading the option with shopt -p needs a subshell.
    if ! shopt -q extglob; then
      shopt -s extglob
      enabled=1
    fi
    # shellcheck disable=SC2207
    COMPREPLY+=( $(compgen -f -X "!*.@($pattern)" -- "$cur"; compgen -d -- "$cur") )
    if [ "$enabled" = "1" ]; then
      shopt -u extglob
    fi
  else
    # shellcheck disable=SC2207
    COMPREPLY+=( $(compgen -f -- "$cur") )
  fi
  compopt -o filenames 2>/dev/null
}

_quarto_dirs() {
  # shellcheck disable=SC2207
  COMPREPLY+=( $(compgen -d -- "$cur") )
  compopt -o filenames 2>/dev/null
}

# Sets vals to the flags of a command that consume the word after them.
# Assigns rather than echoes, so walking the command line forks nothing.
_quarto_valued() {
  case "$1" in
${all.map(valuedCase).filter(Boolean).join("\n")}
    *) vals="" ;;
  esac
}

_quarto() {
  local cur prev cmd word key vals i pos skip
  COMPREPLY=()
  cur="\${COMP_WORDS[COMP_CWORD]}"
  # bash 3.2 rejects a negative array subscript, so guard the first word.
  prev=""
  if [ "$COMP_CWORD" -gt 0 ]; then
    prev="\${COMP_WORDS[COMP_CWORD-1]}"
  fi

  # '=' is in COMP_WORDBREAKS, so '--to=html' arrives as the three words
  # '--to', '=', 'html'. Reunite them: the value dispatch below keys on the
  # flag, and the '=' itself is never the word being completed.
  if [ "$cur" = "=" ]; then
    cur=""
  elif [ "$prev" = "=" ] && [ "$COMP_CWORD" -ge 2 ]; then
    prev="\${COMP_WORDS[COMP_CWORD-2]}"
  fi

  cmd="quarto"
  _quarto_valued "$cmd"
  pos=0
  skip=0
  for (( i=1; i < COMP_CWORD; i++ )); do
    word="\${COMP_WORDS[i]}"
    if [ "$skip" = "1" ]; then
      skip=0
      # A valued flag written '--to=html' consumes two words here, the '='
      # and the value, not one.
      if [ "$word" = "=" ]; then
        skip=1
      fi
      continue
    fi
    case "$word" in
      -*)
        case " $vals " in
          *" $word "*) skip=1 ;;
        esac
        continue
        ;;
    esac
    key="\${cmd}_\${word//[^A-Za-z0-9]/_}"
    case " $_quarto_nodes " in
      *" $key "*)
        cmd="$key"
        _quarto_valued "$cmd"
        pos=0
        continue
        ;;
    esac
    pos=$(( pos + 1 ))
  done

  # A flag that expects a value takes precedence over everything else.
  case "\${cmd}:::\${prev}" in
${all.map(valueCases).filter(Boolean).join("\n")}
  esac

  if [[ "$cur" == -* ]]; then
    case "$cmd" in
${all.map(flagCase).join("\n")}
    esac
    return
  fi

  if [ "$pos" = "0" ]; then
    case "$cmd" in
${all.map(subcommandCase).filter(Boolean).join("\n")}
    esac
  fi

  case "\${cmd}:::\${pos}" in
${all.flatMap(positionalCases).join("\n")}
  esac
}

complete -o bashdefault -o default -F _quarto quarto
`;
}

function valuedCase(command: CommandSpec): string {
  const consuming = valuedFlags(command);
  if (consuming.length === 0) {
    return "";
  }
  return `    ${nodeId(command.path)}) vals="${consuming.join(" ")}" ;;`;
}

function valueCases(command: CommandSpec): string {
  const id = nodeId(command.path);
  return valuedOptions(command)
    .map((option) => {
      const patterns = optionFlags(option)
        .map((flag) => `${id}:::${flag}`)
        .join("|");
      return `    ${patterns}) ${completer(option.kind, option.values, option.globs)} return ;;`;
    })
    .join("\n");
}

function flagCase(command: CommandSpec): string {
  return `      ${nodeId(command.path)}) _quarto_words "${flags(command).join(" ")}"; return ;;`;
}

function subcommandCase(command: CommandSpec): string {
  if (command.commands.length === 0) {
    return "";
  }
  const names = command.commands.map(commandName).join(" ");
  return `      ${nodeId(command.path)}) _quarto_words "${names}" ;;`;
}

function positionalCases(command: CommandSpec): string[] {
  const id = nodeId(command.path);
  const args = positionals(command);
  return args.map((arg, index) => {
    const last = index === args.length - 1;
    // A trailing variadic keeps applying, so match every later index too.
    const pattern = last && trailingIsVariadic(command)
      ? `${id}:::${index}|${id}:::[0-9]*`
      : `${id}:::${index}`;
    return `    ${pattern}) ${completer(arg.kind, arg.values, arg.globs)} return ;;`;
  });
}

function completer(
  kind: ArgSpec["kind"],
  values: string[] | undefined,
  globs: string[] | undefined,
): string {
  switch (kind) {
    case "enum":
      return `_quarto_words "${(values ?? []).join(" ")}";`;
    case "file":
      return `_quarto_files "${(globs ?? []).join("|")}";`;
    case "dir":
      return `_quarto_dirs;`;
    default:
      return `:;`;
  }
}
