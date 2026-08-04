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
          `'${slot}:${singleQuote(arg.name)}:${argAction(arg.kind, arg.values, arg.globs)}'`,
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
      .map((child) => `'${singleQuote(commandName(child))}:${escapeDescription(child.description)}'`)
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
 * one would truncate it and leave the rest to be parsed as a spec.
 */
function escapeDescription(text: string): string {
  return singleQuote(oneLine(text).replace(/([[\]])/g, "\\$1"));
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
    ? `:${option.placeholder ?? "value"}:${argAction(option.kind, option.values, option.globs)}`
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
      return `(${(values ?? []).map(singleQuote).join(" ")})`;
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
