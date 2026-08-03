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
import { commandName } from "../spec.ts";
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
  const paths = all
    .filter((command) => command.path.length > 0)
    .map((command) => `"${command.path.join(" ")}"`)
    .join(" ");

  return `${banner(spec, "#")}

set -g __quarto_nodes ${paths}

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
  return `    case '${command.path.join(" ")}'\n      echo "${consuming.join(" ")}"`;
}

function commandCompletions(command: CommandSpec): string[] {
  const path = command.path.join(" ");
  const lines: string[] = [];

  for (const child of command.commands) {
    lines.push(
      `complete -c quarto -n '__quarto_at "${path}" 0' -f -a ${quote(commandName(child))} -d ${
        quote(oneLine(child.description))
      }`,
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
    lines.push(`complete -c quarto -n '__quarto_at "${path}" ${slot}' ${action}`);
  }

  for (const option of command.options) {
    const forms = [
      option.short ? `-s ${option.short.replace(/^-/, "")}` : "",
      option.long ? `-l ${option.long.replace(/^--/, "")}` : "",
    ].filter(Boolean).join(" ");
    const value = option.kind === "none"
      ? "-f"
      : `-r ${argumentAction(option.kind, option.values, option.globs) ?? "-f"}`;
    lines.push(
      `complete -c quarto -n '__quarto_at "${path}"' ${forms} ${value} -d ${
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
      return `-f -a ${quote((values ?? []).join(" "))}`;
    case "file":
      return globs && globs.length > 0
        ? `-F -a "(__fish_complete_suffix ${globs.map((glob) => `.${glob}`).join(" ")})"`
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
