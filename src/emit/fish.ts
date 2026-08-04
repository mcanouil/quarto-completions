/**
 * Emits a self-contained fish completion script.
 *
 * fish completions are flat: one `complete` line per candidate, guarded by a
 * condition. `__quarto_at` walks the words typed so far, keeps only those that
 * are known commands, and reports both the command path and how many
 * positionals follow it, so `quarto publish gh-pages <TAB>` offers a path
 * rather than another provider.
 */

import type { ArgSpec, CommandSpec, Spec } from "../spec.ts";
import { commandName, nodeId } from "../spec.ts";
import {
  banner,
  nodes,
  oneLine,
  positionals,
  singleQuote,
  trailingIsVariadic,
  valuedFlags,
} from "./common.ts";

export function emitFish(spec: Spec): string {
  const all = nodes(spec);
  // quote(), not a bare "...": a command name comes from `quarto --help`
  // output, which the dev channel sources from an unreviewed, third-party
  // branch, and this is literal source read the moment the file is sourced,
  // not only when a completion runs.
  const paths = all
    .filter((command) => command.path.length > 0)
    .map((command) => quote(command.path.join(" ")))
    .join(" ");

  return `${banner(spec, "#")}

set -g __quarto_nodes ${paths}

# fish re-expands a literal -a candidate list at completion time, running
# any (...) a candidate carries rather than treating it as inert text --
# this is fish's own documented mechanism for generating candidates from a
# command's output, e.g. 'complete -a "(ls)"', and applies to every word in
# the list, not only one spelled as the whole argument. Verified against
# real fish. Candidates instead reach this as ordinary, already-quoted
# arguments to a function call, which is not re-evaluated the same way.
function __quarto_words
  printf '%s\n' $argv
end

# Flags of a command that consume the word after them.
function __quarto_valued --argument-names node
  switch "$node"
${all.map(valuedCase).filter(Boolean).join("\n")}
    case '*'
      echo ""
  end
end

# Resolves the command path and the number of positionals after it. Every
# completion below is guarded by a condition, and fish evaluates one per
# distinct condition, so the answer is cached against the command line it was
# computed from rather than recomputed for each.
function __quarto_resolve
  set -l line (commandline -opc)
  if test "$__quarto_line" = "$line"
    return
  end
  set -g __quarto_line $line

  set -l words $line
  set -e words[1]
  set -l path ""
  set -l vals
  set -l pos 0
  set -l skip 0
  for word in $words
    if test $skip -eq 1
      set skip 0
      continue
    end
    if string match -qr -- '^-' "$word"
      if contains -- "$word" $vals
        set skip 1
      end
      continue
    end
    set -l candidate (string trim -- "$path $word")
    if contains -- "$candidate" $__quarto_nodes
      set path "$candidate"
      set vals (string split " " -- (__quarto_valued "$path"))
      set pos 0
      continue
    end
    set pos (math $pos + 1)
  end

  set -g __quarto_path "$path"
  set -g __quarto_pos $pos
end

# True when the command line is at command path $target, optionally with
# exactly $index positionals typed, or at least $index when it ends in '+'.
function __quarto_at --argument-names target index
  __quarto_resolve

  test "$__quarto_path" = "$target"; or return 1
  test -z "$index"; and return 0

  if string match -q -- '*+' "$index"
    test $__quarto_pos -ge (string replace -- '+' '' "$index")
  else
    test $__quarto_pos -eq "$index"
  end
end

${all.flatMap(commandCompletions).join("\n")}
`;
}

function valuedCase(command: CommandSpec): string {
  const consuming = valuedFlags(command);
  if (consuming.length === 0) {
    return "";
  }
  // quote(), not a bare '...': a command name comes from `quarto --help`
  // output, which the dev channel sources from an unreviewed, third-party
  // branch, and an unescaped ' would end the case pattern's string early.
  return `    case ${quote(command.path.join(" "))}\n      echo ${quote(consuming.join(" "))}`;
}

function commandCompletions(command: CommandSpec): string[] {
  const path = command.path.join(" ");
  // A -n condition is parsed twice: once as this file is sourced, again
  // when `complete` evaluates it as a condition command, through `eval` or
  // its equivalent -- and that second pass has its own, apparently
  // undocumented rules for a backslash next to a quote, different enough
  // from ordinary fish parsing that no quoting scheme embedding path
  // directly in the condition text survived real testing. path instead sits
  // once, as an ordinary string literal, in this function's body: source
  // parsed only when the file is sourced, the same as every other
  // command name or flag already baked into this script rather than
  // rebuilt from text at completion time. -n conditions below call it by
  // this safe, sanitised name and a trusted index, neither of which is
  // untrusted text that needs escaping at all.
  const conditionFn = `__quarto_is_${nodeId(command.path)}`;
  const lines: string[] = [
    `function ${conditionFn} --argument-names index`,
    `  __quarto_at ${quote(path)} $index`,
    `end`,
  ];
  const at = (index?: string) => `${conditionFn}${index === undefined ? "" : ` ${index}`}`;

  for (const child of command.commands) {
    lines.push(
      `complete -c quarto -n '${at("0")}' -f -a "(__quarto_words ${
        quote(commandName(child))
      })" -d ${quote(oneLine(child.description))}`,
    );
  }

  const args = positionals(command);
  for (const [index, arg] of args.entries()) {
    const action = argumentAction(arg.kind, arg.values, arg.globs);
    if (!action) {
      continue;
    }
    const last = index === args.length - 1;
    const slot = last && trailingIsVariadic(command) ? `${index}+` : `${index}`;
    lines.push(`complete -c quarto -n '${at(slot)}' ${action}`);
  }

  for (const option of command.options) {
    // Quoted: a flag spelling comes from `quarto --help` output, which the
    // dev channel sources from an unreviewed, third-party branch. Left bare,
    // a form carrying a space would hand `complete` an extra word where a
    // flag of its own belongs.
    const forms = [
      option.short ? `-s ${quote(option.short.replace(/^-/, ""))}` : "",
      option.long ? `-l ${quote(option.long.replace(/^--/, ""))}` : "",
    ].filter(Boolean).join(" ");
    const value = option.kind === "none"
      ? "-f"
      : `-r ${argumentAction(option.kind, option.values, option.globs) ?? "-f"}`;
    lines.push(
      `complete -c quarto -n '${at()}' ${forms} ${value} -d ${
        quote(oneLine(option.description))
      }`,
    );
  }

  return lines;
}

function argumentAction(
  kind: ArgSpec["kind"],
  values: string[] | undefined,
  globs: string[] | undefined,
): string | undefined {
  switch (kind) {
    case "enum":
      return `-f -a "(__quarto_words ${(values ?? []).map(quote).join(" ")})"`;
    case "file":
      // One call per suffix: fish only accepts several suffixes in one call
      // from 3.6 on, and older versions read the second argument as the token
      // to complete, which silently breaks the whole filter.
      return globs && globs.length > 0
        ? `-F -a "(${globs.map((glob) => `__fish_complete_suffix .${glob}`).join("; ")})"`
        : `-F`;
    case "dir":
      return `-f -a "(__fish_complete_directories)"`;
    default:
      return undefined;
  }
}

function quote(text: string): string {
  return `'${singleQuote(text)}'`;
}
