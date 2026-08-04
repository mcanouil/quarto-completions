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
        specs.push(`'${slot}:${arg.name}:${argAction(arg.kind, arg.values, arg.globs)}'`);
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
      .map((child) => `'${commandName(child)}:${escapeDescription(child.description)}'`)
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
        `        ${commandName(child)}) ${functionName(child.path)} ;;`
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

function optionSpec(option: OptionSpec): string {
  const description = escapeDescription(option.description);
  const forms = optionFlags(option);
  const exclusion = `(${forms.join(" ")})`;
  // A trailing '=' on the long form tells _arguments the value may sit in the
  // same word after '=' as well as in the next word, so '--to=html' completes.
  const spelled = forms.map((form) =>
    option.kind !== "none" && form.startsWith("--") ? `${form}=` : form
  );
  const flag = spelled.length > 1 ? `{${spelled.join(",")}}` : `${spelled[0]}`;
  const value = option.kind === "none"
    ? ""
    : `:${option.placeholder ?? "value"}:${argAction(option.kind, option.values, option.globs)}`;
  return `'${exclusion}'${flag}'[${description}]${value}'`;
}

function argAction(
  kind: string,
  values: string[] | undefined,
  globs: string[] | undefined,
): string {
  switch (kind) {
    case "enum":
      return `(${(values ?? []).join(" ")})`;
    case "file":
      return globs && globs.length > 0 ? `_files -g "*.(${globs.join("|")})"` : `_files`;
    case "dir":
      return `_files -/`;
    default:
      return ` `;
  }
}
