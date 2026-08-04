/**
 * Emits a self-contained bash completion script.
 *
 * The script never runs `quarto`: every candidate is baked in. It targets bash
 * 3.2, which is what macOS ships, so no associative arrays and no `${var^^}`.
 *
 * Words typed so far are walked once, which resolves three things at the same
 * time: the command path, how many positionals have been supplied, and which
 * words were consumed as flag values rather than positionals. Before the walk,
 * words that readline split on '=' or ':' (both in COMP_WORDBREAKS) are glued
 * back together, so '--to=html' and 'key:value' each count as one word.
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
  local cur prev cmd word key vals i pos skip words cword raw
  COMPREPLY=()

  # '=' and ':' are both in COMP_WORDBREAKS, so '--to=html' arrives as the
  # three words '--to', '=', 'html', and 'key:value' is split the same way.
  # Reassemble once; everything below reads the glued words.
  words=("\${COMP_WORDS[0]}")
  cword=0
  for (( i=1; i <= COMP_CWORD; i++ )); do
    raw="\${COMP_WORDS[i]}"
    if [[ "$raw" == [=:] ]] || [[ "\${COMP_WORDS[i-1]}" == [=:] ]]; then
      words[\${#words[@]}-1]="\${words[\${#words[@]}-1]}\${raw}"
    else
      words[\${#words[@]}]="$raw"
    fi
    if [ "$i" -eq "$COMP_CWORD" ]; then
      cword=$(( \${#words[@]} - 1 ))
    fi
  done

  cur="\${words[cword]}"
  # bash 3.2 rejects a negative array subscript, so guard the first word.
  prev=""
  if [ "$cword" -gt 0 ]; then
    prev="\${words[cword-1]}"
  fi
  # A flag with its value attached dispatches on the flag; the part after '='
  # is the word being completed.
  case "$cur" in
    -*=*)
      prev="\${cur%%=*}"
      cur="\${cur#*=}"
      ;;
  esac

  cmd="quarto"
  _quarto_valued "$cmd"
  pos=0
  skip=0
  for (( i=1; i < cword; i++ )); do
    word="\${words[i]}"
    if [ "$skip" = "1" ]; then
      skip=0
      continue
    fi
    case "$word" in
      # A value attached with '=' travels inside the flag's own word.
      -*=*) continue ;;
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
  return `    ${nodeId(command.path)}) vals="${doubleQuoted(consuming.join(" "))}" ;;`;
}

function valueCases(command: CommandSpec): string {
  const id = nodeId(command.path);
  return valuedOptions(command)
    .map((option) => {
      const patterns = optionFlags(option)
        .map((flag) => `${id}:::${casePattern(flag)}`)
        .join("|");
      return `    ${patterns}) ${completer(option.kind, option.values, option.globs)} return ;;`;
    })
    .join("\n");
}

function flagCase(command: CommandSpec): string {
  return `      ${nodeId(command.path)}) _quarto_words "${
    doubleQuoted(flags(command).join(" "))
  }"; return ;;`;
}

function subcommandCase(command: CommandSpec): string {
  if (command.commands.length === 0) {
    return "";
  }
  const names = command.commands.map(commandName).join(" ");
  return `      ${nodeId(command.path)}) _quarto_words "${doubleQuoted(names)}" ;;`;
}

/**
 * Escapes text bound for a double-quoted bash string literal in the
 * generated script. Command names, flags, and enum values come from `quarto
 * --help` output, which the dev channel sources from an unreviewed,
 * third-party branch; without this, a value carrying a `"` would end the
 * literal early and the rest would be read as script source, not data.
 */
function doubleQuoted(text: string): string {
  return text.replace(/(["\\$`])/g, "\\$1");
}

/**
 * Escapes text bound for a bash `case` pattern in the generated script. The
 * pattern sits unquoted in the source, so it undergoes ordinary shell
 * tokenising as the file is parsed, not just pattern matching: an unescaped
 * `"` or `'` opens real quoting there and swallows everything up to the next
 * one, `)` ends the pattern list early, and `$` or a backtick expands.
 * Backslash-escaping every character outside a safe allowlist, rather than
 * enumerating the dangerous ones, is what closed an earlier, incomplete
 * version of this function that escaped glob characters but not quotes.
 */
function casePattern(text: string): string {
  return text.replace(/[^A-Za-z0-9_./-]/g, "\\$&");
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
      return `_quarto_words "${doubleQuoted((values ?? []).join(" "))}";`;
    case "file":
      return `_quarto_files "${doubleQuoted((globs ?? []).join("|"))}";`;
    case "dir":
      return `_quarto_dirs;`;
    default:
      return `:;`;
  }
}
