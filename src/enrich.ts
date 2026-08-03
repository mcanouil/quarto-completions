/**
 * Applies `overlay.ts` to a parsed spec, so that emitters read a single
 * structure in which every option and positional already knows how it is
 * completed.
 */

import type { CommandSpec, Spec } from "./spec.ts";
import { applyOverride, overrideFor } from "./overlay.ts";

export function enrich(spec: Spec): Spec {
  return { ...spec, root: enrichCommand(spec.root) };
}

function enrichCommand(command: CommandSpec): CommandSpec {
  const override = overrideFor(command.path);

  const options = command.options.map((option) =>
    applyOverride(
      option,
      override.options[option.long ?? ""] ?? override.options[option.short ?? ""],
    )
  );

  const declared = new Set(options.map((option) => option.long));
  for (const option of override.extraOptions ?? []) {
    if (!declared.has(option.long)) {
      options.push(option);
    }
  }

  return {
    ...command,
    options,
    args: command.args.map((arg) => applyOverride(arg, override.args[arg.name])),
    commands: command.commands.map(enrichCommand),
  };
}
