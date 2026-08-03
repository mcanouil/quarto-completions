/**
 * Generates the completion scripts.
 *
 *     quarto run src/generate.ts [--quarto <path>] [--channel stable|prerelease]
 *                                [--out <dir>] [--check]
 *
 * `--check` writes nothing and exits non-zero when the committed output differs
 * from what the installed Quarto would produce, which is what CI runs to notice
 * that the CLI surface moved.
 */

import { enrich } from "./enrich.ts";
import { introspect } from "./introspect.ts";
import { emitBash } from "./emit/bash.ts";
import { emitFish } from "./emit/fish.ts";
import { emitPwsh } from "./emit/pwsh.ts";
import { emitZsh } from "./emit/zsh.ts";
import type { Spec } from "./spec.ts";

interface Options {
  quarto: string;
  channel: Spec["channel"];
  out: string;
  check: boolean;
}

function parseArgs(args: string[]): Options {
  const options: Options = {
    quarto: "quarto",
    channel: "stable",
    out: "docs/completions",
    check: false,
  };
  for (let index = 0; index < args.length; index++) {
    switch (args[index]) {
      case "--quarto":
        options.quarto = args[++index];
        break;
      case "--channel": {
        const channel = args[++index];
        if (channel !== "stable" && channel !== "prerelease") {
          throw new Error(`--channel must be stable or prerelease, got '${channel}'`);
        }
        options.channel = channel;
        break;
      }
      case "--out":
        options.out = args[++index];
        break;
      case "--check":
        options.check = true;
        break;
      default:
        throw new Error(`Unknown argument '${args[index]}'`);
    }
  }
  return options;
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
        generated: spec.generated,
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
  const spec = await introspect({ quarto: options.quarto, channel: options.channel });
  const files = render(spec);
  files["manifest.json"] = await manifest(spec, files);

  const directory = `${options.out}/${options.channel}`;

  if (options.check) {
    const differences: string[] = [];
    for (const [name, content] of Object.entries(files)) {
      // The manifest and spec carry a generation date, which changes on every
      // run and says nothing about the CLI surface.
      if (name === "manifest.json" || name === "spec.json") {
        continue;
      }
      const path = `${directory}/${name}`;
      const existing = await Deno.readTextFile(path).catch(() => undefined);
      if (existing !== content) {
        differences.push(path);
      }
    }
    if (differences.length > 0) {
      console.error(
        `Completions are out of date for Quarto ${spec.quartoVersion}:\n  ${
          differences.join("\n  ")
        }\nRun: quarto run src/generate.ts --channel ${options.channel}`,
      );
      Deno.exit(1);
    }
    console.log(`Completions match Quarto ${spec.quartoVersion} (${options.channel}).`);
    return;
  }

  await Deno.mkdir(directory, { recursive: true });
  for (const [name, content] of Object.entries(files)) {
    await Deno.writeTextFile(`${directory}/${name}`, content);
  }
  console.log(
    `Wrote ${Object.keys(files).length} files to ${directory} for Quarto ${spec.quartoVersion}.`,
  );
}

if (import.meta.main) {
  await main();
}
