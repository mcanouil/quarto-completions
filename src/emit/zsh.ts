/**
 * Emits a self-contained zsh completion script.
 *
 * One function per command, wired together with `_arguments` states, which is
 * the idiomatic shape and the only one of the four that shows descriptions
 * beside every candidate.
 */

import type { CommandSpec, OptionSpec, Spec } from "../spec.ts";
import { commandName, nodeId } from "../spec.ts";
import { banner, nodes, oneLine, positionals, singleQuote } from "./common.ts";

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
        const slot = last && arg.variadic ? "*" : `${index + 1}`;
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
    const describe = command.commands
      .map((child) => `'${commandName(child)}:${singleQuote(oneLine(child.description))}'`)
      .join(" \\\n      ");
    body.push(
      `  case $state in`,
      `    command)`,
      `      local -a subcommands`,
      `      subcommands=( \\`,
      `      ${describe} \\`,
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

function optionSpec(option: OptionSpec): string {
  const description = singleQuote(oneLine(option.description));
  const forms = [option.short, option.long].filter(Boolean) as string[];
  const exclusion = `(${forms.join(" ")})`;
  const flag = forms.length > 1 ? `{${forms.join(",")}}` : `${forms[0]}`;
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
