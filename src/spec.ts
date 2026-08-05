/**
 * Shape of the Quarto CLI surface, as parsed from `quarto --help`.
 *
 * The spec is the single intermediate representation: `introspect.ts` fills it
 * in, `overlay.ts` enriches it, and every emitter reads it and nothing else.
 */

/** How a value is completed once a flag or positional expects one. */
export type ValueKind =
  /** The flag is a switch and takes no value. */
  | "none"
  /** A value is expected, but nothing sensible can be suggested. */
  | "value"
  /** Complete file paths, filtered by `globs` when present. */
  | "file"
  /** Complete directories only. */
  | "dir"
  /** Complete from the fixed `values` list. */
  | "enum";

export interface OptionSpec {
  /** Short form, including the dash, e.g. `-t`. */
  short?: string;
  /** Long form, including the dashes, e.g. `--to`. */
  long?: string;
  /** Placeholder shown in help between angle brackets, e.g. `level`. */
  placeholder?: string;
  description: string;
  kind: ValueKind;
  /** Candidates when `kind` is `enum`. */
  values?: string[];
  /** File name patterns when `kind` is `file`, e.g. `qmd`, `ipynb`. */
  globs?: string[];
}

export interface ArgSpec {
  /** Name as it appears in the usage line, e.g. `input`. */
  name: string;
  optional: boolean;
  variadic: boolean;
  kind: ValueKind;
  values?: string[];
  globs?: string[];
}

export interface CommandSpec {
  /** Command path below `quarto`, e.g. `["publish", "accounts"]`. Empty at the root. */
  path: string[];
  description: string;
  options: OptionSpec[];
  args: ArgSpec[];
  commands: CommandSpec[];
}

/**
 * A channel is `release` or `pre-release`, both of which move as Quarto ships;
 * `dev`, generated from a 99.9.9 source build; or a Quarto minor such as `1.9`,
 * an archive frozen at that line's newest patch once a later minor supersedes
 * it.
 */
export type Channel = "release" | "pre-release" | "dev" | `${number}.${number}`;

/**
 * True when `channel` names a Quarto minor line, e.g. `1.9`. Matches only
 * `<major>.<minor>`: `1`, `1.9.3`, and `v1.9` are refused, so a typo cannot
 * name a directory nothing will ever publish.
 */
export function isVersionChannel(channel: string): channel is `${number}.${number}` {
  return /^\d+\.\d+$/.test(channel);
}

/** The `<major>.<minor>` prefix of a version string, or undefined. */
export function majorMinor(version: string): string | undefined {
  return /^(\d+\.\d+)/.exec(version)?.[1];
}

export interface Spec {
  /** Version reported by the binary that was introspected. */
  quartoVersion: string;
  /** Release channel the binary came from. */
  channel: Channel;
  root: CommandSpec;
}

/** Every command in the tree, root first, depth first. */
export function walk(command: CommandSpec): CommandSpec[] {
  return [command, ...command.commands.flatMap(walk)];
}

/** Last segment of a command path, e.g. `accounts`; `quarto` at the root. */
export function commandName(command: CommandSpec): string {
  return command.path[command.path.length - 1] ?? "quarto";
}

/** Identifier-safe join of a command path, e.g. `quarto_publish_accounts`. */
export function nodeId(path: string[]): string {
  return ["quarto", ...path].join("_").replace(/[^A-Za-z0-9_]/g, "_");
}

/** Every flag form an option can be written as. */
export function optionFlags(option: OptionSpec): string[] {
  return [option.short, option.long].filter((flag): flag is string => !!flag);
}
