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
import { render } from "../src/generate.ts";
import { emitBash } from "../src/emit/bash.ts";
import { emitFish } from "../src/emit/fish.ts";
import { emitPwsh } from "../src/emit/pwsh.ts";
import { emitZsh } from "../src/emit/zsh.ts";
import type { CommandSpec, OptionSpec, Spec } from "../src/spec.ts";

const fixtures = new Map<string, string>();

function fixture(name: string): string {
  // Read through the URL rather than its `pathname`, which on Windows would be
  // `/C:/...` and reach no file. Cached, since the suite builds the same spec
  // from the same five files for every test.
  let text = fixtures.get(name);
  if (text === undefined) {
    text = Deno.readTextFileSync(new URL(`fixtures/${name}.txt`, import.meta.url));
    fixtures.set(name, text);
  }
  return text;
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

  // These two iterate `render()` rather than a list of their own, so a fifth
  // emitter is covered the moment it is added to the generator.
  "no generated file calls quarto at completion time"() {
    for (const [name, output] of Object.entries(render(fixtureSpec()))) {
      assertExcludes(output, "quarto completions complete", `${name} shells out`);
    }
  },

  "every generated file carries the version it came from"() {
    for (const [name, output] of Object.entries(render(fixtureSpec()))) {
      assertIncludes(output, "1.10.18", `${name} has no version`);
    }
  },

  "two runs of the same spec produce identical files"() {
    // What `--check` rests on: a difference means the CLI surface moved, not
    // that the generator was run twice.
    assertEquals(render(fixtureSpec()), render(fixtureSpec()));
  },

  "a generated script carries no date, so it is stable between runs"() {
    for (const [name, output] of Object.entries(render(fixtureSpec()))) {
      if (name.endsWith(".json")) {
        continue;
      }
      assertExcludes(output, "generated 2", `${name} stamps a date into every run`);
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

  "fish filters files one suffix at a time"() {
    // fish only accepts several suffixes in one __fish_complete_suffix call
    // from 3.6 on; older versions read the second argument as the token to
    // complete, so each suffix must arrive in a call of its own.
    const output = emitFish(enrich(fixtureSpec()));
    assertIncludes(output, "__fish_complete_suffix .qmd; __fish_complete_suffix .ipynb");
  },

  "powershell gates every valued flag, not only the enums"() {
    // A valued flag missing from Values would fall through to the subcommand
    // candidates; an empty list makes the completer return nothing instead.
    const output = emitPwsh(enrich(fixtureSpec()));
    assertIncludes(output, "'--profile' = @()");
  },

  "the generator refuses a completable positional beside subcommands"() {
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.args.push({ name: "shape", optional: true, variadic: false, kind: "enum", values: ["x"] });
    let message = "";
    try {
      render(spec);
    } catch (error) {
      message = (error as Error).message;
    }
    assertIncludes(message, "'quarto call'");
    assertIncludes(message, "shape");
  },

  "a bare value positional beside subcommands is tolerated"() {
    // `use <type> [target]` restates its subcommands in the usage line; there
    // is nothing to complete, so dropping it loses nothing.
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.args.push({ name: "type", optional: false, variadic: false, kind: "value" });
    render(spec);
  },

  "powershell registers both the binary and the shim"() {
    const output = emitPwsh(fixtureSpec());
    assertIncludes(output, "-CommandName quarto -ScriptBlock");
    assertIncludes(output, "-CommandName quarto.cmd -ScriptBlock");
  },

  "zsh escapes brackets, which would otherwise truncate a description"() {
    const spec = fixtureSpec();
    spec.root.commands[0].options.push({
      long: "--bracketed",
      description: "Writes [DIR] somewhere.",
      kind: "none",
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "\\[DIR\\]");
    assertExcludes(output, "[Writes [DIR] somewhere.]");
  },

  "bash guards the word before the first argument"() {
    const output = emitBash(enrich(fixtureSpec()));
    assertIncludes(output, `if [ "$COMP_CWORD" -gt 0 ]; then`);
  },

  "bash reunites a flag split on = with its value"() {
    // bash keeps '=' in COMP_WORDBREAKS, so '--to=html' reaches the function
    // as three words and the script has to put them back together.
    const output = emitBash(enrich(fixtureSpec()));
    assertIncludes(output, `if [ "$cur" = "=" ]; then`);
    assertIncludes(output, `elif [ "$prev" = "=" ]`);
  },

  "zsh accepts a value attached with = on long options"() {
    const output = emitZsh(enrich(fixtureSpec()));
    assertIncludes(output, "--to=");
    // Switches take no value, so they must not grow the suffix.
    assertExcludes(output, "--toc=");
  },

  "descriptions are escaped for the shell that shows them"() {
    const spec = fixtureSpec();
    // `--output` reads "use '--output -' for stdout", which is the only
    // description in the surface carrying single quotes.
    assertIncludes(emitZsh(spec), `'\\''--output -'\\''`);
    assertIncludes(emitPwsh(spec), `''--output -''`);
  },
};


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
