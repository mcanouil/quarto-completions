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

/** Help invocations to run at once. Each one is a cold Quarto start. */
const kConcurrency = 6;

export interface IntrospectOptions {
  /** Path to the `quarto` binary to introspect. */
  quarto: string;
  channel: Spec["channel"];
}

export async function introspect(options: IntrospectOptions): Promise<Spec> {
  const version = (await run(options.quarto, ["--version"])).trim();
  const root = await introspectCommand(options.quarto, []);
  return {
    quartoVersion: version,
    channel: options.channel,
    generated: new Date().toISOString().slice(0, 10),
    root,
  };
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
      description: (sections.get("Description") ?? []).map((l) => l.trim()).join(" ").trim(),
      options,
      args,
      commands: [],
    },
    children: parseCommands(sections.get("Commands") ?? []),
  };
}

async function introspectCommand(
  quarto: string,
  path: string[],
): Promise<CommandSpec> {
  const help = await run(quarto, [...path, "--help"]);
  const { command: parsed, children } = parseHelp(help, path);

  const commands: CommandSpec[] = [];
  for (const batch of chunk(children.filter((c) => !kSkippedCommands.has(c.name)), kConcurrency)) {
    const resolved = await Promise.all(
      batch.map((child) => introspectCommand(quarto, [...path, child.name])),
    );
    for (const [index, command] of resolved.entries()) {
      commands.push({ ...command, description: batch[index].description });
    }
  }

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

function chunk<T>(items: T[], size: number): T[][] {
  const batches: T[][] = [];
  for (let index = 0; index < items.length; index += size) {
    batches.push(items.slice(index, index + size));
  }
  return batches;
}
