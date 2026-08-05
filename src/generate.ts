/**
 * Generates the completion scripts.
 *
 *     quarto run src/generate.ts [--quarto <path>] [--channel release|pre-release|dev|<major.minor>]
 *                                [--out <dir>] [--mirror] [--check]
 *                                [--source-branch <name>] [--source-commit <sha>]
 *
 * `--check` writes nothing and exits non-zero when the committed output differs
 * from what the installed Quarto would produce, which is what CI runs to notice
 * that the CLI surface moved.
 *
 * `--mirror` writes the same surface a second time, under the minor the binary
 * reports: `release` and `pre-release` name whichever lines Quarto ships today
 * and move without warning, where `1.10` stays where it is. Only those two
 * channels can be mirrored; a version channel is already its own minor, and a
 * 99.9.9 source build has no released line to claim.
 *
 * `--source-branch` and `--source-commit` name the `quarto-dev/quarto-cli`
 * build behind a `dev` run, which is the one channel whose version says
 * nothing: every source build reports 99.9.9. Both are recorded in
 * `manifest.json` and in each script's header. A released channel takes
 * neither, since its tag is its version with a `v` in front of it.
 *
 * The `dev` channel only ever comes from a 99.9.9 source build: that is the
 * version Quarto's own `kLocalDevelopment` constant reports, and it is the one
 * build where `dev-call` and the rest of the hidden surface `introspect.ts`
 * seeds exist to be introspected. `introspect()` fails fast when the channel
 * and the binary's version disagree, before spending a cold Quarto start per
 * command on a tree walk that would otherwise fail confusingly partway
 * through.
 */

import { enrich } from "./enrich.ts";
import { introspect } from "./introspect.ts";
import { emitBash } from "./emit/bash.ts";
import { emitFish } from "./emit/fish.ts";
import { emitPwsh } from "./emit/pwsh.ts";
import { emitZsh } from "./emit/zsh.ts";
import { isVersionChannel, majorMinor } from "./spec.ts";
import type { Channel, Source, Spec } from "./spec.ts";

interface Options {
  quarto: string;
  channel: Channel;
  out: string;
  check: boolean;
  mirror: boolean;
  /** Branch a `dev` build came from; unset everywhere else. */
  branch?: string;
  /** Commit that build was at; unset everywhere else. */
  commit?: string;
}

export function parseArgs(args: string[]): Options {
  const options: Options = {
    quarto: "quarto",
    channel: "release",
    out: "docs/completions",
    check: false,
    mirror: false,
  };
  /**
   * The argument after `index`, or a failure naming the flag that wanted one.
   * Read unchecked, a flag written last hands back undefined and fails much
   * later: on spawning a binary called "undefined", or reporting a channel of
   * "undefined" that nothing on the command line ever named.
   */
  const value = (index: number): string => {
    const next = args[index];
    if (next === undefined) {
      throw new Error(`${args[index - 1]} needs a value`);
    }
    return next;
  };
  for (let index = 0; index < args.length; index++) {
    switch (args[index]) {
      case "--quarto":
        options.quarto = value(++index);
        break;
      case "--channel": {
        const channel = value(++index);
        if (channel !== "release" && channel !== "pre-release" && channel !== "dev" && !isVersionChannel(channel)) {
          throw new Error(
            `--channel must be release, pre-release, dev, or a Quarto minor such as '1.9', got '${channel}'`,
          );
        }
        options.channel = channel;
        break;
      }
      case "--out":
        options.out = value(++index);
        break;
      case "--check":
        options.check = true;
        break;
      case "--mirror":
        options.mirror = true;
        break;
      case "--source-branch": {
        const branch = value(++index);
        // The header is the one place a caller's own words reach a generated
        // script, and only the first line of it is commented: a newline here
        // would put the rest into bash, zsh, fish, and PowerShell as code.
        // Held to the shape of a branch name, which also refuses an empty
        // value, reaching the stamp as '@<commit>', and a mistyped flag read
        // as the name it was meant to precede.
        if (!/^[A-Za-z0-9][A-Za-z0-9._/-]*$/.test(branch)) {
          throw new Error(`--source-branch must be a branch name, got '${branch}'`);
        }
        options.branch = branch;
        break;
      }
      case "--source-commit": {
        const commit = value(++index);
        // Checked on the way in: a stamp reading 'main@HEAD' or naming a tag
        // would otherwise be published and believed.
        if (!/^[0-9a-f]{7,40}$/.test(commit)) {
          throw new Error(`--source-commit must be a commit SHA, got '${commit}'`);
        }
        options.commit = commit;
        break;
      }
      default:
        throw new Error(`Unknown argument '${args[index]}'`);
    }
  }
  // Checked here rather than in the case above, where '--mirror' written
  // before '--channel' would be judged against the default channel and let a
  // pair through that the same pair in the other order is refused for.
  if (options.mirror && options.channel !== "release" && options.channel !== "pre-release") {
    throw new Error(
      `--mirror needs --channel release or pre-release, got '${options.channel}'`,
    );
  }
  // Same reason, and a released channel has nothing to say here anyway: its
  // source is the tag its own version names, so a branch or a commit passed
  // beside it could only contradict what is written.
  if (options.channel !== "dev" && (options.branch !== undefined || options.commit !== undefined)) {
    throw new Error(
      `--source-branch and --source-commit need --channel dev, got '${options.channel}'`,
    );
  }
  return options;
}

/**
 * Where the surface came from, as far as the command line and the binary's own
 * version say: a tag on a released channel, and whatever the build passed on
 * `dev`, which reports 99.9.9 and so names no tag at all. Undefined when there
 * is nothing to record, which is a local `dev` run and a version `introspect()`
 * could not read.
 */
export function sourceFor(spec: Spec, options: Options): Source | undefined {
  if (spec.channel === "dev") {
    if (options.branch === undefined && options.commit === undefined) {
      return undefined;
    }
    return {
      ...(options.branch !== undefined ? { branch: options.branch } : {}),
      ...(options.commit !== undefined ? { commit: options.commit } : {}),
    };
  }
  if (majorMinor(spec.quartoVersion) === undefined) {
    return undefined;
  }
  return { tag: `v${spec.quartoVersion}` };
}

/**
 * The version channel a mirrored run also writes, e.g. `1.10` for Quarto
 * 1.10.18: the same surface under the minor it came from, beside the moving
 * channel that will point somewhere else once Quarto ships the next line.
 */
export function mirrorChannel(spec: Spec): `${number}.${number}` {
  const minor = majorMinor(spec.quartoVersion);
  if (minor === undefined || !isVersionChannel(minor)) {
    throw new Error(`Cannot mirror Quarto '${spec.quartoVersion}': it names no major.minor`);
  }
  return minor;
}

/** Files written for a channel, keyed by their name on disk. */
export function render(spec: Spec): Record<string, string> {
  const enriched = enrich(spec);
  return {
    "quarto.bash": emitBash(enriched),
    "_quarto": emitZsh(enriched),
    "quarto.fish": emitFish(enriched),
    "quarto.ps1": emitPwsh(enriched),
    "spec.json": `${JSON.stringify(enriched, null, 2)}\n`,
  };
}

async function manifest(
  spec: Spec,
  files: Record<string, string>,
): Promise<string> {
  const entries: Record<string, string> = {};
  for (const [name, content] of Object.entries(files)) {
    entries[name] = await sha256(content);
  }
  return `${
    JSON.stringify(
      {
        quartoVersion: spec.quartoVersion,
        channel: spec.channel,
        ...(spec.source !== undefined ? { source: spec.source } : {}),
        // The only field that changes without the CLI surface changing, which
        // is why the manifest is the only file excluded from the drift check.
        generated: new Date().toISOString().slice(0, 10),
        files: entries,
      },
      null,
      2,
    )
  }\n`;
}

async function sha256(content: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(content));
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function main(): Promise<void> {
  const options = parseArgs(Deno.args);
  const introspected = await introspect({ quarto: options.quarto, channel: options.channel });
  // Attached before the mirror is derived, so both channels of a mirrored run
  // name the same artefact. Written field by field rather than spread, which
  // would append `source` after the whole command tree in spec.json.
  const spec: Spec = {
    quartoVersion: introspected.quartoVersion,
    channel: introspected.channel,
    source: sourceFor(introspected, options),
    root: introspected.root,
  };
  // One introspection, one or two channels: the mirror is the same surface
  // written under the minor it came from, so the binary is never walked twice
  // to say the same thing in a different directory.
  const specs = options.mirror ? [spec, { ...spec, channel: mirrorChannel(spec) }] : [spec];
  const mirror = options.mirror ? " --mirror" : "";

  if (options.check) {
    const differences: string[] = [];
    for (const written of specs) {
      for (const [name, content] of Object.entries(render(written))) {
        const path = `${options.out}/${written.channel}/${name}`;
        const existing = await Deno.readTextFile(path).catch(() => undefined);
        if (existing !== content) {
          differences.push(path);
        }
      }
    }
    if (differences.length > 0) {
      console.error(
        `Completions are out of date for Quarto ${spec.quartoVersion}:\n  ${
          differences.join("\n  ")
        }\nRun: quarto run src/generate.ts --channel ${options.channel}${mirror}`,
      );
      Deno.exit(1);
    }
    console.log(
      `Completions match Quarto ${spec.quartoVersion} (${
        specs.map((written) => written.channel).join(", ")
      }).`,
    );
    return;
  }

  for (const written of specs) {
    const files = render(written);
    files["manifest.json"] = await manifest(written, files);
    const directory = `${options.out}/${written.channel}`;
    await Deno.mkdir(directory, { recursive: true });
    for (const [name, content] of Object.entries(files)) {
      await Deno.writeTextFile(`${directory}/${name}`, content);
    }
    console.log(
      `Wrote ${Object.keys(files).length} files to ${directory} for Quarto ${written.quartoVersion}.`,
    );
  }
}

if (import.meta.main) {
  await main();
}
