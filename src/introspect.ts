/**
 * Parses `quarto <path> --help` into a `Spec`.
 *
 * Quarto builds its CLI with Cliffy and renders help with colours disabled, so
 * the output is plain, column-aligned text with a stable shape:
 *
 *     Usage:   quarto render [input] [args...]
 *     Version: 1.10.18
 *
 *     Description:
 *
 *       Render files or projects to various document types.
 *
 *     Options:
 *
 *       -t, --to                     - Specify output format(s).
 *       --log-level       <level>    - Log level (debug, info, warning, error, critical)
 *
 *     Commands:
 *
 *       help  [command]  - Show this help or the help of a sub-command.
 *
 * Entries start at an indent of exactly two spaces; anything indented further
 * continues the entry above it, which is how Cliffy wraps long descriptions.
 */

import type { ArgSpec, CommandSpec, OptionSpec, Spec, ValueKind } from "./spec.ts";

/** Commands that exist but are not worth completing. */
const kSkippedCommands = new Set(["help"]);

/**
 * Commands Cliffy marks `.hidden()`, which keeps them out of their parent's
 * `--help` output and out of ordinary recursion, even though each still
 * answers `--help` itself. Only surfaced on the `dev` channel: a release
 * binary hides them exactly as it hides `dev-call`, so completing them for
 * `stable` or `prerelease` would offer commands their users cannot see.
 */
const kHiddenCommands: string[][] = [
  ["capabilities"],
  ["inspect"],
  ["editor-support"],
  ["create-project"],
  ["completions"],
  ["dev-call"],
  ["tools", "install"],
  ["tools", "info"],
  ["tools", "uninstall"],
  ["tools", "update"],
  ["tools", "list"],
  ["dev-call", "validate-yaml"],
  ["dev-call", "build-artifacts"],
  ["dev-call", "show-ast-trace"],
  ["dev-call", "make-ast-diagram"],
  ["dev-call", "pull-git-subtree"],
  ["dev-call", "typst-gather"],
];

/** Names hidden directly below `path`, on the `dev` channel only. */
export function hiddenChildrenFor(path: string[], channel: Spec["channel"]): string[] {
  if (channel !== "dev") {
    return [];
  }
  return kHiddenCommands
    .filter((hidden) => isChildOf(hidden, path))
    .map((hidden) => hidden[hidden.length - 1]);
}

/** Whether `candidate` names a command directly below `path`. */
function isChildOf(candidate: string[], path: string[]): boolean {
  return candidate.length === path.length + 1 &&
    path.every((segment, index) => segment === candidate[index]);
}

/**
 * Help invocations in flight at once, across the whole tree. Each one is a
 * cold Quarto start, so the cap is on total processes rather than per level.
 */
const kConcurrency = 6;

export interface IntrospectOptions {
  /** Path to the `quarto` binary to introspect. */
  quarto: string;
  channel: Spec["channel"];
}

export async function introspect(options: IntrospectOptions): Promise<Spec> {
  const permits = new Semaphore(kConcurrency);
  const rootHelp = await permits.run(() => run(options.quarto, ["--help"]));
  const root = await introspectCommand(options.quarto, [], rootHelp, permits, options.channel);
  return {
    // Help output reports the version itself, which saves a cold start that
    // `quarto --version` would otherwise cost before anything else can begin.
    quartoVersion: /^Version:\s+(\S+)/m.exec(rootHelp)?.[1] ?? "unknown",
    channel: options.channel,
    root,
  };
}

/** Caps how many Quarto processes run at once, without batching barriers. */
class Semaphore {
  #free: number;
  #waiting: (() => void)[] = [];

  constructor(permits: number) {
    this.#free = permits;
  }

  async run<T>(work: () => Promise<T>): Promise<T> {
    if (this.#free === 0) {
      await new Promise<void>((resolve) => this.#waiting.push(resolve));
    } else {
      this.#free--;
    }
    try {
      return await work();
    } finally {
      const next = this.#waiting.shift();
      if (next) {
        next();
      } else {
        this.#free++;
      }
    }
  }
}

/**
 * Turns one command's help output into a spec, along with the names of the
 * subcommands still to be visited. Pure, so tests exercise it against captured
 * fixtures without running Quarto.
 */
export function parseHelp(
  help: string,
  path: string[],
): { command: CommandSpec; children: { name: string; description: string }[] } {
  const sections = splitSections(help);
  const { options, passthrough } = parseOptions(sections.get("Options") ?? []);
  const args = parseUsage(help, path);
  if (passthrough) {
    args.push(passthrough);
  }
  return {
    command: {
      path,
      description: descriptionText(sections.get("Description") ?? []),
      options,
      args,
      commands: [],
    },
    children: parseCommands(sections.get("Commands") ?? []),
  };
}

/**
 * Joins the description's lines, stopping before an `Arguments:` block.
 *
 * Cliffy renders a command's own argument table inside its description when
 * one is declared that way, which `dev-call pull-git-subtree` does. Nothing
 * marks that block off from an ordinary heading, since it sits indented
 * inside the section `splitSections` already carved out; without the cut, a
 * one-line description would swallow the whole table.
 */
function descriptionText(lines: string[]): string {
  const cut = lines.findIndex((line) => line.trim() === "Arguments:");
  return (cut === -1 ? lines : lines.slice(0, cut)).map((l) => l.trim()).join(" ").trim();
}

async function introspectCommand(
  quarto: string,
  path: string[],
  help: string,
  permits: Semaphore,
  channel: Spec["channel"],
): Promise<CommandSpec> {
  const { command: parsed, children } = parseHelp(help, path);

  const visit = children.filter((child) => !kSkippedCommands.has(child.name));
  const known = new Set(children.map((child) => child.name));
  // Hidden children have no entry in the parent's own command table, so there
  // is no description to override theirs with; they keep the one their own
  // help output carries.
  const seeded = hiddenChildrenFor(path, channel).filter((name) => !known.has(name));

  const commands = await Promise.all([
    ...visit.map(async (child) => {
      const childPath = [...path, child.name];
      const childHelp = await permits.run(() => run(quarto, [...childPath, "--help"]));
      const command = await introspectCommand(quarto, childPath, childHelp, permits, channel);
      return { ...command, description: child.description };
    }),
    ...seeded.map(async (name) => {
      const childPath = [...path, name];
      const childHelp = await permits.run(() => run(quarto, [...childPath, "--help"]));
      return introspectCommand(quarto, childPath, childHelp, permits, channel);
    }),
  ]);

  return { ...parsed, commands };
}

/**
 * Groups help output by its top-level headings (`Options:`, `Commands:`, …),
 * dropping blank lines and the heading itself.
 */
function splitSections(help: string): Map<string, string[]> {
  const sections = new Map<string, string[]>();
  let current: string[] | undefined;
  for (const line of help.split("\n")) {
    const heading = /^(\w[\w ]*):\s*$/.exec(line);
    if (heading) {
      current = [];
      sections.set(heading[1], current);
      continue;
    }
    if (line.trim() === "") {
      continue;
    }
    // `Usage:` and `Version:` carry their value on the heading line itself and
    // open no section.
    if (/^\w[\w ]*:\s+\S/.test(line)) {
      current = undefined;
      continue;
    }
    current?.push(line.replace(/\s+$/, ""));
  }
  return sections;
}

/** Rejoins wrapped entries: indent of exactly two starts one, deeper continues it. */
function entries(lines: string[]): string[] {
  const out: string[] = [];
  for (const line of lines) {
    const indent = line.length - line.trimStart().length;
    if (indent === 2 || out.length === 0) {
      out.push(line.trim());
    } else {
      out[out.length - 1] += ` ${line.trim()}`;
    }
  }
  return out.map((entry) => entry.replace(/\s+/g, " ").trim());
}

/** Splits an entry into its left-hand signature and its description. */
function splitEntry(entry: string): { left: string; description: string } {
  const separator = / - (?=[^-]|$)/.exec(entry);
  if (!separator) {
    return { left: entry.trim(), description: "" };
  }
  return {
    left: entry.slice(0, separator.index).trim(),
    description: entry.slice(separator.index + 3).trim(),
  };
}

function parseOptions(
  lines: string[],
): { options: OptionSpec[]; passthrough?: ArgSpec } {
  const options: OptionSpec[] = [];
  const negatable = new Set<string>();
  let passthrough: ArgSpec | undefined;

  for (const entry of entries(lines)) {
    const { left, description } = splitEntry(entry);
    if (!left.startsWith("-")) {
      // Cliffy lists a variadic passthrough argument, such as
      // `pandoc-args...`, among the options.
      const name = left.replace(/\.\.\.$/, "");
      if (name) {
        passthrough = {
          name,
          optional: true,
          variadic: left.endsWith("..."),
          kind: "value",
        };
      }
      continue;
    }

    // A placeholder is written `<level>` when the value is required and
    // `[editor]` when it is optional.
    const placeholderMatch = /[<[]([^>\]]+)[>\]]\s*$/.exec(left);
    const placeholder = placeholderMatch?.[1];
    const flags = left
      .replace(/[<[][^>\]]+[>\]]\s*$/, "")
      .split(",")
      .map((flag) => flag.trim())
      .filter(Boolean);

    const option: OptionSpec = {
      short: flags.find((flag) => /^-[^-]/.test(flag)),
      long: flags.find((flag) => flag.startsWith("--")),
      placeholder,
      description,
      kind: placeholder ? "value" : "none",
    };

    const values = harvestEnum(description);
    if (placeholder && values) {
      option.kind = "enum";
      option.values = values;
    }

    options.push(option);

    for (const flag of description.match(/--no-[a-z][a-z0-9-]*/g) ?? []) {
      negatable.add(flag);
    }
  }

  const known = new Set(options.flatMap((option) => [option.short, option.long]));
  for (const flag of negatable) {
    if (!known.has(flag)) {
      options.push({
        long: flag,
        description: `Negated form of --${flag.slice(5)}.`,
        kind: "none",
      });
    }
  }

  return { options, passthrough };
}

/**
 * Reads a value set out of a trailing parenthesised list, so that
 * `Log level (debug, info, warning, error, critical)` completes its levels.
 */
function harvestEnum(description: string): string[] | undefined {
  const match = /\(([a-z0-9][a-z0-9-]*(?:,\s*[a-z0-9][a-z0-9-]*)+)\)\.?$/.exec(
    description.trim(),
  );
  if (!match) {
    return undefined;
  }
  return match[1].split(",").map((value) => value.trim());
}

function parseCommands(lines: string[]): { name: string; description: string }[] {
  const commands: { name: string; description: string }[] = [];
  for (const entry of entries(lines)) {
    const { left, description } = splitEntry(entry);
    const name = left.split(/\s+/)[0];
    if (name && !name.startsWith("-")) {
      commands.push({ name, description });
    }
  }
  return commands;
}

/** Reads positional arguments from the usage line, e.g. `[input] [args...]`. */
function parseUsage(help: string, path: string[]): ArgSpec[] {
  const usage = /^Usage:\s+(.*)$/m.exec(help)?.[1] ?? "";
  const tokens = usage.trim().split(/\s+/).slice(1 + path.length);
  return tokens.flatMap((token): ArgSpec[] => {
    const match = /^([[<])(.+?)([\]>])$/.exec(token);
    if (!match) {
      return [];
    }
    const variadic = match[2].endsWith("...");
    return [{
      name: match[2].replace(/\.\.\.$/, ""),
      optional: match[1] === "[",
      variadic,
      kind: "value" as ValueKind,
    }];
  });
}

async function run(quarto: string, args: string[]): Promise<string> {
  const command = new Deno.Command(quarto, {
    args,
    stdout: "piped",
    stderr: "piped",
    env: { NO_COLOR: "1" },
  });
  const { code, stdout, stderr } = await command.output();
  if (code !== 0) {
    throw new Error(
      `quarto ${args.join(" ")} exited with ${code}: ${new TextDecoder().decode(stderr)}`,
    );
  }
  return new TextDecoder().decode(stdout);
}
