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

import { isVersionChannel, majorMinor } from "./spec.ts";
import type { ArgSpec, Channel, CommandSpec, OptionSpec, Spec, ValueKind } from "./spec.ts";

/** Commands that exist but are not worth completing. */
const kSkippedCommands = new Set(["help"]);

/**
 * Commands Cliffy marks `.hidden()`, which keeps them out of their parent's
 * `--help` output and out of ordinary recursion, even though each still
 * answers `--help` itself. Only surfaced on the `dev` channel: a released
 * binary hides them exactly as it hides `dev-call`, so completing them on
 * `release`, `pre-release`, or a version channel would offer commands their
 * users cannot see.
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
export function hiddenChildrenFor(path: string[], channel: Channel): string[] {
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
 * Fallback descriptions for hidden commands whose own `--help` declares none
 * at all, such as every `tools` subcommand. Applied only when the command's
 * own help output is silent, so a hidden command that does describe itself
 * keeps its own words.
 */
const kHiddenDescriptions: Record<string, string> = {
  "tools install": "Installs a global dependency.",
  "tools info": "Shows the status of a global dependency.",
  "tools uninstall": "Uninstalls a global dependency.",
  "tools update": "Updates a global dependency.",
  "tools list": "Lists the status of every global dependency.",
};

/** What Quarto's own `kLocalDevelopment` reports for an unreleased source build. */
export const kDevVersion = "99.9.9";

/**
 * Fails fast when the channel and the binary's version disagree, before the
 * tree walk that would otherwise spend one cold Quarto start per command only
 * to fail confusingly partway through: `dev` seeds commands that do not exist
 * outside a source build, and no other channel must ever seed them. A version
 * channel such as `1.9` is checked the same way, against the binary's own
 * major and minor, so archiving against the wrong tarball fails immediately
 * rather than publishing a mismatched surface.
 */
export function assertChannelMatchesVersion(channel: Channel, quartoVersion: string): void {
  const isDevBuild = quartoVersion === kDevVersion;
  if (channel === "dev" && !isDevBuild) {
    throw new Error(
      `--channel dev needs a ${kDevVersion} source build, got Quarto ${quartoVersion}`,
    );
  }
  if (channel !== "dev" && isDevBuild) {
    throw new Error(
      `Quarto ${kDevVersion} is a source build; generate it with --channel dev, not '${channel}'`,
    );
  }
  if (isVersionChannel(channel) && majorMinor(quartoVersion) !== channel) {
    throw new Error(
      `--channel ${channel} needs a Quarto ${channel}.x build, got ${quartoVersion}`,
    );
  }
}

/**
 * Help invocations in flight at once, across the whole tree. Each one is a
 * cold Quarto start, so the cap is on total processes rather than per level.
 */
const kConcurrency = 6;

export interface IntrospectOptions {
  /** Path to the `quarto` binary to introspect. */
  quarto: string;
  channel: Channel;
}

export async function introspect(options: IntrospectOptions): Promise<Spec> {
  const permits = new Semaphore(kConcurrency);
  const rootHelp = await permits.run(() => run(options.quarto, ["--help"]));
  // Help output reports the version itself, which saves a cold start that
  // `quarto --version` would otherwise cost before anything else can begin,
  // and lets the channel be checked against it before any other command runs.
  const quartoVersion = /^Version:\s+(\S+)/m.exec(rootHelp)?.[1] ?? "unknown";
  assertChannelMatchesVersion(options.channel, quartoVersion);
  const root = await introspectCommand(options.quarto, [], rootHelp, permits, options.channel);
  return { quartoVersion, channel: options.channel, root };
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

/**
 * A seeded child keeps whatever its own help output carries, unlike a
 * discovered one, which is always overwritten with the short phrase from its
 * parent's command table (see the `visit` branch below). Cliffy's own
 * `Description:` block is prose, not that short phrase, so it is cut to its
 * first sentence to match the length every other command in the tree has.
 */
export function firstSentence(text: string): string {
  const end = text.indexOf(". ");
  return end === -1 ? text : text.slice(0, end + 1);
}

async function introspectCommand(
  quarto: string,
  path: string[],
  help: string,
  permits: Semaphore,
  channel: Channel,
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
    ...seeded.map(async (name): Promise<CommandSpec | undefined> => {
      const childPath = [...path, name];
      let childHelp: string;
      try {
        childHelp = await permits.run(() => run(quarto, [...childPath, "--help"]));
      } catch {
        // Seeded paths are a hardcoded list checked against a moving branch of
        // quarto-cli: one renamed or removed hidden command must not fail the
        // whole tree, the way a genuinely broken discovered command should.
        console.error(
          `warning: 'quarto ${childPath.join(" ")}' no longer answers --help; dropped from the dev channel`,
        );
        return undefined;
      }
      const command = await introspectCommand(quarto, childPath, childHelp, permits, channel);
      return {
        ...command,
        description: firstSentence(command.description) ||
          kHiddenDescriptions[childPath.join(" ")] || "",
      };
    }),
  ]);

  return {
    ...parsed,
    commands: commands.filter((command): command is CommandSpec => command !== undefined),
  };
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

/**
 * The environment a spawned `quarto` gets: the current process's own, minus
 * every `QUARTO_*` variable.
 *
 * Quarto's launcher script exports these (`QUARTO_BIN_PATH`, `QUARTO_DENO`,
 * `QUARTO_SHARE_PATH`, `QUARTO_ROOT`, ...) to tell its own `quarto.js` where
 * it and its resources live, and it only computes each one when the variable
 * is not already set. `generate.ts --quarto <path>` is exactly this process
 * running inside its own such launcher, so those variables are already set
 * to its paths; left in a spawned child's environment unfiltered, an
 * archived binary being introspected would skip computing its own and reuse
 * the running Quarto's `quarto.js`, `deno`, and `share/` instead, so `--help`
 * silently answers for the wrong version. Filtering them out here is what
 * makes archiving a different Quarto than the one running the generator (see
 * `scripts/archive-minor.sh`) work at all; inheriting the rest keeps `PATH`,
 * `HOME`, and everything else the launcher and `deno` still need.
 */
export function childEnv(source: Record<string, string> = Deno.env.toObject()): Record<string, string> {
  const env = { ...source };
  for (const key of Object.keys(env)) {
    if (key.startsWith("QUARTO")) {
      delete env[key];
    }
  }
  env.NO_COLOR = "1";
  return env;
}

async function run(quarto: string, args: string[]): Promise<string> {
  const command = new Deno.Command(quarto, {
    args,
    stdout: "piped",
    stderr: "piped",
    clearEnv: true,
    env: childEnv(),
  });
  const { code, stdout, stderr } = await command.output();
  if (code !== 0) {
    throw new Error(
      `quarto ${args.join(" ")} exited with ${code}: ${new TextDecoder().decode(stderr)}`,
    );
  }
  return new TextDecoder().decode(stdout);
}
