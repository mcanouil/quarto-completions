/**
 * Test suite.
 *
 *     quarto run tests/run.ts
 *
 * Everything here runs against the captured help output under `fixtures/`, so
 * no Quarto process is started and the results do not drift with the version
 * that happens to be installed.
 */

import { assert, assertEquals, assertExcludes, assertIncludes } from "./assert.ts";
import { parseHelp } from "../src/introspect.ts";
import { enrich } from "../src/enrich.ts";
import { emitBash } from "../src/emit/bash.ts";
import { emitFish } from "../src/emit/fish.ts";
import { emitPwsh } from "../src/emit/pwsh.ts";
import { emitZsh } from "../src/emit/zsh.ts";
import type { CommandSpec, OptionSpec, Spec } from "../src/spec.ts";

const here = new URL(".", import.meta.url).pathname;

function fixture(name: string): string {
  return Deno.readTextFileSync(`${here}fixtures/${name}.txt`);
}

function option(command: CommandSpec, flag: string): OptionSpec {
  const found = command.options.find(
    (candidate) => candidate.long === flag || candidate.short === flag,
  );
  if (!found) {
    throw new Error(`no option '${flag}' on 'quarto ${command.path.join(" ")}'`);
  }
  return found;
}

/** A spec built from the fixtures, standing in for a full introspection. */
function fixtureSpec(): Spec {
  const root = parseHelp(fixture("root"), []).command;
  const render = parseHelp(fixture("render"), ["render"]).command;
  const publish = parseHelp(fixture("publish"), ["publish"]).command;
  const create = parseHelp(fixture("create"), ["create"]).command;
  const call = parseHelp(fixture("call"), ["call"]);

  root.commands = [
    render,
    publish,
    create,
    {
      ...call.command,
      commands: call.children.map((child) => ({
        path: ["call", child.name],
        description: child.description,
        options: [],
        args: [],
        commands: [],
      })),
    },
  ];

  return {
    quartoVersion: "1.10.18",
    channel: "stable",
    generated: "2026-08-03",
    root,
  };
}

const tests: Record<string, () => void> = {
  "root help lists every command"() {
    const { children } = parseHelp(fixture("root"), []);
    const names = children.map((child) => child.name);
    for (const expected of ["render", "preview", "publish", "call", "check"]) {
      assert(names.includes(expected), `root is missing '${expected}': ${names.join(", ")}`);
    }
  },

  "root help parses its own options"() {
    const { command } = parseHelp(fixture("root"), []);
    assertEquals(option(command, "--help").short, "-h");
    assertEquals(option(command, "--version").short, "-V");
  },

  "wrapped descriptions are rejoined"() {
    const { children } = parseHelp(fixture("root"), []);
    const update = children.find((child) => child.name === "update");
    assert(update !== undefined, "no 'update' command");
    assertIncludes(update!.description, "Chrome Headless Shell");
    assertExcludes(update!.description, "\n");
  },

  "a parenthesised list becomes a value set"() {
    const { command } = parseHelp(fixture("render"), ["render"]);
    assertEquals(option(command, "--log-level").kind, "enum");
    assertEquals(option(command, "--log-level").values, [
      "debug",
      "info",
      "warning",
      "error",
      "critical",
    ]);
    assertEquals(option(command, "--log-format").values, ["plain", "json-stream"]);
  },

  "an optional placeholder is read like a required one"() {
    const { command } = parseHelp(fixture("create"), ["create"]);
    assertEquals(option(command, "--open").placeholder, "editor");
    assertEquals(option(command, "--open").values, ["positron", "vscode", "rstudio"]);
  },

  "a negated form mentioned in a description becomes a flag"() {
    const { command } = parseHelp(fixture("render"), ["render"]);
    assertEquals(option(command, "--no-execute").kind, "none");
    assertEquals(option(command, "--no-cache").kind, "none");
  },

  "positionals come from the usage line"() {
    const { command } = parseHelp(fixture("publish"), ["publish"]);
    assertEquals(command.args.map((arg) => arg.name), ["provider", "path"]);
    assertEquals(command.args.map((arg) => arg.optional), [true, true]);
  },

  "a passthrough argument is not treated as an option"() {
    const { command } = parseHelp(fixture("render"), ["render"]);
    assert(
      command.options.every((candidate) => candidate.long !== "pandoc-args..."),
      "pandoc-args... leaked into the options",
    );
    assert(
      command.args.some((arg) => arg.name === "pandoc-args" && arg.variadic),
      "pandoc-args... is missing from the arguments",
    );
  },

  "the overlay gives --to its formats"() {
    const render = enrich(fixtureSpec()).root.commands[0];
    assertEquals(option(render, "--to").kind, "enum");
    assert(
      (option(render, "--to").values ?? []).includes("revealjs"),
      "--to does not offer revealjs",
    );
  },

  "the overlay adds the forwarded pandoc options"() {
    const render = enrich(fixtureSpec()).root.commands[0];
    assertEquals(option(render, "--toc").kind, "none");
    assertEquals(option(render, "--pdf-engine").kind, "enum");
  },

  "the overlay keeps --profile a value option"() {
    const render = enrich(fixtureSpec()).root.commands[0];
    assertEquals(option(render, "--profile").kind, "value");
  },

  "no emitter calls quarto at completion time"() {
    const spec = fixtureSpec();
    for (const [shell, output] of Object.entries(emitAll(spec))) {
      assertExcludes(output, "quarto completions complete", `${shell} shells out`);
    }
  },

  "every emitter carries the version it was generated from"() {
    const spec = fixtureSpec();
    for (const [shell, output] of Object.entries(emitAll(spec))) {
      assertIncludes(output, "1.10.18", `${shell} has no version banner`);
    }
  },

  "bash registers a completion function"() {
    const output = emitBash(enrich(fixtureSpec()));
    assertIncludes(output, "complete -o bashdefault -o default -F _quarto quarto");
    assertIncludes(output, "quarto_render:::--to");
  },

  "zsh declares itself a compdef"() {
    const output = emitZsh(enrich(fixtureSpec()));
    assert(output.startsWith("#compdef quarto"), "missing #compdef header");
    assertIncludes(output, "_quarto_render()");
  },

  "zsh never defines a function that would shadow the binary"() {
    const output = emitZsh(enrich(fixtureSpec()));
    assertExcludes(output, "\nquarto() {", "defines a bare 'quarto' function");
    assertIncludes(output, "_quarto() {");
  },

  "fish resolves the command path before completing"() {
    const output = emitFish(fixtureSpec());
    assertIncludes(output, "function __quarto_at");
    assertIncludes(output, `__quarto_at "render"`);
  },

  "powershell registers both the binary and the shim"() {
    const output = emitPwsh(fixtureSpec());
    assertIncludes(output, "-CommandName quarto -ScriptBlock");
    assertIncludes(output, "-CommandName quarto.cmd -ScriptBlock");
  },

  "descriptions are escaped for the shell that shows them"() {
    const spec = fixtureSpec();
    // `--output` reads "use '--output -' for stdout", which is the only
    // description in the surface carrying single quotes.
    assertIncludes(emitZsh(spec), `'\\''--output -'\\''`);
    assertIncludes(emitPwsh(spec), `''--output -''`);
  },
};

function emitAll(spec: Spec): Record<string, string> {
  const enriched = enrich(spec);
  return {
    bash: emitBash(enriched),
    zsh: emitZsh(enriched),
    fish: emitFish(enriched),
    pwsh: emitPwsh(enriched),
  };
}

let failures = 0;
for (const [name, test] of Object.entries(tests)) {
  try {
    test();
    console.log(`ok    ${name}`);
  } catch (error) {
    failures++;
    console.error(`FAIL  ${name}`);
    console.error(`      ${(error as Error).message.replace(/\n/g, "\n      ")}`);
  }
}

console.log(`\n${Object.keys(tests).length - failures} passed, ${failures} failed.`);
if (failures > 0) {
  Deno.exit(1);
}
