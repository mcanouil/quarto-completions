/**
 * Emits a self-contained zsh completion script.
 *
 * One function per command, wired together with `_arguments` states, which is
 * the idiomatic shape and the only one of the four that shows descriptions
 * beside every candidate.
 */

import type { CommandSpec, OptionSpec, Spec } from "../spec.ts";
import { commandName, nodeId, optionFlags } from "../spec.ts";
import { banner, nodes, oneLine, positionals, singleQuote, trailingIsVariadic } from "./common.ts";

export function emitZsh(spec: Spec): string {
  const all = nodes(spec);
  // Everything after a subcommand-bearing command goes to the subcommand
  // machinery below, so a positional there is silently dropped. `use` is
  // shaped like this today and loses nothing: its positionals are the
  // subcommands restated, with no candidates of their own. A positional that
  // does carry candidates would disappear without this check.
  for (const command of all) {
    const completable = positionals(command).filter((arg) => arg.kind !== "value");
    if (command.commands.length > 0 && completable.length > 0) {
      throw new Error(
        `'quarto ${command.path.join(" ")}' has subcommands and a completable positional ` +
          `(${completable.map((arg) => arg.name).join(", ")}); the zsh emitter would drop it.`,
      );
    }
  }
  return `#compdef quarto
${banner(spec, "#")}

# _arguments re-evaluates a literal (a b c) action list at completion time,
# running any $(...) or \`...\` an enum value carries rather than treating it
# as inert text; verified against real zsh. Values instead reach compadd as
# ordinary, already-quoted arguments to this function, which is not
# re-evaluated the same way.
#
# _arguments calls an action command with the compadd options it built for the
# spec's message prepended to the arguments written here, so '--' marks where
# those end and the values begin. Without the split they are offered as
# candidates: '-J' and '-default-' always, and '-M' plus the matcher itself
# wherever a matcher-list style is set, which is any Oh My Zsh. With no '--'
# present every argument is taken for an option and nothing is offered, rather
# than the options being listed as values.
_quarto_enum() {
  local -i split=\${argv[(i)--]}
  local -a options=("\${(@)argv[1,split-1]}") candidates=("\${(@)argv[split+1,-1]}")
  # -a, so a value is never read as an option of compadd's own.
  compadd "\${(@)options}" -a candidates
}

${all.map(commandFunction).join("\n\n")}

_quarto "$@"
`;
}

/**
 * Function name for a command. The leading underscore is what keeps the root
 * function `_quarto` rather than `quarto`, which would shadow the binary.
 */
function functionName(path: string[]): string {
  return `_${nodeId(path)}`;
}

function commandFunction(command: CommandSpec): string {
  const id = functionName(command.path);
  const hasCommands = command.commands.length > 0;
  const specs = command.options.map(optionSpec);

  if (hasCommands) {
    specs.push(`'1: :->command'`, `'*:: :->argument'`);
  } else {
    const args = positionals(command);
    if (args.length === 0) {
      specs.push(`'*: :_files'`);
    } else {
      for (const [index, arg] of args.entries()) {
        const last = index === args.length - 1;
        const slot = last && trailingIsVariadic(command) ? "*" : `${index + 1}`;
        specs.push(
          `'${slot}:${specLabel(arg.name)}:${
            singleQuote(argAction(arg.kind, arg.values, arg.globs))
          }'`,
        );
      }
    }
  }

  const body = [
    `  local context state state_descr line`,
    `  typeset -A opt_args`,
    ``,
    `  _arguments -C -s \\`,
    specs.map((spec) => `    ${spec}`).join(" \\\n"),
    ``,
  ];

  if (hasCommands) {
    const subcommandList = command.commands
      .map((child) => `'${specLabel(commandName(child))}:${escapeDescription(child.description)}'`)
      .join(" \\\n      ");
    body.push(
      `  case $state in`,
      `    command)`,
      `      local -a subcommands`,
      `      subcommands=( \\`,
      `      ${subcommandList} \\`,
      `      )`,
      `      _describe -t commands 'quarto command' subcommands`,
      `      ;;`,
      `    argument)`,
      `      case $words[1] in`,
      ...command.commands.map((child) =>
        `        ${bareWord(commandName(child))}) ${functionName(child.path)} ;;`
      ),
      `      esac`,
      `      ;;`,
      `  esac`,
    );
  }

  return `${id}() {\n${body.join("\n")}\n}`;
}

/**
 * zsh reads an option description up to the matching `]`, so a bracket inside
 * one would truncate it and leave the rest to be parsed as a spec. A
 * trailing backslash needs the same treatment: verified against real zsh,
 * one there escapes the `]` that follows, and _arguments then reports the
 * whole spec as an invalid option definition and drops every flag on the
 * command, not only this one.
 */
function escapeDescription(text: string): string {
  return singleQuote(oneLine(text).replace(/([\\[\]])/g, "\\$1"));
}

/**
 * Escapes text for a zsh spec label: the message before an action
 * (`:message:action`), or a `_describe` candidate's name before its
 * description (`name:description`). An unescaped `:` there ends the field
 * early, and the field that follows is read as a fresh spec component in its
 * own right, not as more of this one. Verified against real zsh: a
 * placeholder carrying a `:` followed by a `{...}` eval-string action ran a
 * command the moment it was offered. `'` still needs the same outer-quote
 * escaping every other value in this spec gets.
 */
function specLabel(text: string): string {
  return singleQuote(text.replace(/[\\:]/g, "\\$&"));
}

/**
 * Escapes text for a bare, unquoted zsh word: a flag spelling, or a `case`
 * pattern matching a command name. Both come from `quarto --help` output,
 * which the dev channel sources from an unreviewed, third-party branch, and
 * both stay outside shell quotes on purpose (a flag so zsh's own brace
 * expansion can turn `{-t,--to}` into one spec per form; a case pattern
 * because that is the only place one goes). Left unescaped, this text is
 * parsed as script source the moment the file is read, not as data: an
 * unquoted `"` or `'` opens real quoting that swallows everything up to the
 * next one, and `)` ends a case pattern list early. Backslash-escaping every
 * character outside a safe allowlist, rather than enumerating the dangerous
 * ones, is what the bash emitter's equivalent needed a second pass to get
 * right.
 */
function bareWord(text: string): string {
  return text.replace(/[^A-Za-z0-9_./=-]/g, "\\$&");
}

function optionSpec(option: OptionSpec): string {
  const description = escapeDescription(option.description);
  const takesValue = option.kind !== "none";
  const forms = optionFlags(option);
  const exclusion = `(${forms.map(singleQuote).join(" ")})`;
  // A trailing '=' on the long form tells _arguments the value may sit in the
  // same word after '=' as well as in the next word, so '--to=html' completes.
  const spelled = forms.map((form) =>
    takesValue && form.startsWith("--") ? `${form}=` : form
  );
  const bareForms = spelled.map(bareWord);
  const flag = bareForms.length > 1 ? `{${bareForms.join(",")}}` : bareForms[0];
  const value = takesValue
    ? `:${specLabel(option.placeholder ?? "value")}:${
      singleQuote(argAction(option.kind, option.values, option.globs))
    }`
    : "";
  return `'${exclusion}'${flag}'[${description}]${value}'`;
}

function argAction(
  kind: string,
  values: string[] | undefined,
  globs: string[] | undefined,
): string {
  switch (kind) {
    case "enum":
      // specLabel(), not singleQuote(): _arguments scans the whole action
      // string for an unescaped ':' before this ever runs as the function
      // call it looks like, and an enum value carrying one is read as
      // introducing a fresh spec field mid-quote. Verified against real
      // zsh: a value of "key:value" broke the quoting so badly that the
      // fragments it produced were read as commands, printing "unmatched
      // '" and "command not found: _" instead of offering anything.
      // '--' first: see _quarto_enum, which splits the compadd options
      // _arguments prepends here from the values written after it.
      return `_quarto_enum -- ${(values ?? []).map((value) => `'${specLabel(value)}'`).join(" ")}`;
    case "file":
      // Globs are never attacker-controlled: they always come from this
      // repo's own overlay.ts constants, never from quarto --help text, so
      // this position is left as-is rather than guessing at the escaping a
      // deferred zsh action string needs for input that can't reach it.
      return globs && globs.length > 0 ? `_files -g "*.(${globs.join("|")})"` : `_files`;
    case "dir":
      return `_files -/`;
    default:
      return ` `;
  }
}
