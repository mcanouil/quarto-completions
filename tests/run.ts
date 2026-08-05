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
import {
  assertChannelMatchesVersion,
  firstSentence,
  hiddenChildrenFor,
  kDevVersion,
  parseHelp,
} from "../src/introspect.ts";
import { enrich } from "../src/enrich.ts";
import { parseArgs, render } from "../src/generate.ts";
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

  "a flag given no value is refused by name"() {
    // Without this, the missing value arrives as undefined and surfaces much
    // later: '--quarto' as the last argument fails when the binary is spawned,
    // and '--channel' reports "got 'undefined'".
    for (const flag of ["--quarto", "--channel", "--out"]) {
      let message = "";
      try {
        parseArgs([flag]);
      } catch (error) {
        message = (error as Error).message;
      }
      assertIncludes(message, flag, `'${flag}' alone was not refused by name`);
      assertIncludes(message, "needs a value", `'${flag}' alone was not refused by name`);
    }
  },

  "a complete argument list still parses"() {
    assertEquals(
      parseArgs(["--quarto", "/tmp/quarto", "--channel", "dev", "--out", "elsewhere", "--check"]),
      { quarto: "/tmp/quarto", channel: "dev", out: "elsewhere", check: true },
    );
    assertEquals(parseArgs([]), {
      quarto: "quarto",
      channel: "stable",
      out: "docs/completions",
      check: false,
    });
  },

  "every script stamps its Quarto version and channel in one parsable line"() {
    // install.sh reads this line out of the scripts already on disk to tell a
    // user which of their shells is holding a stale completion, so its shape
    // is an interface rather than a comment. Rewording it silently turns that
    // advice off.
    const spec = enrich(fixtureSpec());
    const stamp = "# Quarto 1.10.18 (stable channel).";
    for (const output of [emitBash(spec), emitZsh(spec), emitFish(spec), emitPwsh(spec)]) {
      assertIncludes(output, `\n${stamp}\n`);
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
    assertIncludes(output, "function __quarto_is_quarto_render --argument-names index");
    assertIncludes(output, "__quarto_at 'render' $index");
    assertIncludes(output, "-n '__quarto_is_quarto_render'");
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

  "zsh escapes a trailing backslash, which would otherwise escape the closing bracket"() {
    // Verified against real zsh: without this, _arguments reports the whole
    // spec as an invalid option definition and drops every flag on the
    // command, not only this one.
    const spec = fixtureSpec();
    spec.root.commands[0].options.push({
      long: "--evil-desc",
      description: "ends in backslash\\",
      kind: "none",
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "ends in backslash\\\\");
  },

  "zsh escapes a trailing backslash in a spec label the same way"() {
    // specLabel() got the description's trailing-backslash fix above, but
    // was fixed separately; this pins that it now carries the same one.
    // Verified against real zsh: without it, a placeholder ending in a
    // backslash escapes the colon that follows, and the option offers no
    // candidates at all where the clean baseline offered its full list.
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({
      long: "--evil-ph2",
      description: "d",
      kind: "value",
      placeholder: "dir\\",
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "dir\\\\:");
  },

  "zsh escapes a colon in an enum value the same way"() {
    // Verified against real zsh: without this, _arguments's naive
    // colon-scan splits the action string mid-quote, printing "unmatched
    // '" and "command not found: _" instead of offering anything.
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({
      long: "--evil-enum2",
      description: "d",
      kind: "enum",
      values: ["a", "key:value"],
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "key\\:value");
  },

  "bash guards the word before the first argument"() {
    const output = emitBash(enrich(fixtureSpec()));
    assertIncludes(output, `if [ "$cword" -gt 0 ]; then`);
  },

  "bash reassembles words split on wordbreak characters"() {
    // bash keeps '=' and ':' in COMP_WORDBREAKS, so '--to=html' and
    // 'key:value' reach the function in pieces and are glued back together.
    const output = emitBash(enrich(fixtureSpec()));
    assertIncludes(output, `[[ "$raw" == [=:] ]]`);
    assertIncludes(output, `-*=*) continue ;;`);
  },

  "bash routes candidate words through a plain loop rather than compgen -W"() {
    // compgen -W re-expands its wordlist, running any $(...) or `...` a
    // candidate carries rather than treating it as inert text, even one
    // that arrived here already escaped for this file's own parsing.
    // Verified against real bash. A structural check, not a pattern that
    // can be escaped around: the vulnerable shape was any use of
    // `compgen -W` at all, whatever quoting surrounded it.
    const output = emitBash(enrich(fixtureSpec()));
    assertExcludes(output, 'compgen -W "');
  },

  "bash disables globbing around the plain word-split loop"() {
    // An unquoted word-split still performs pathname expansion on its own;
    // verified against real bash, a candidate spelled like a glob (a real
    // flag written with brackets, say) listed unrelated files from the
    // current directory instead of completing as itself.
    const output = emitBash(enrich(fixtureSpec()));
    assertIncludes(output, "set -f");
    assertIncludes(output, "set +f");
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

  "hidden commands are seeded only on the dev channel"() {
    for (const channel of ["stable", "prerelease"] as const) {
      assertEquals(hiddenChildrenFor([], channel), []);
      assertEquals(hiddenChildrenFor(["dev-call"], channel), []);
    }
  },

  "the dev channel seeds the root's hidden commands"() {
    const names = hiddenChildrenFor([], "dev");
    for (const expected of ["capabilities", "inspect", "editor-support", "create-project", "completions", "dev-call"]) {
      assert(names.includes(expected), `root is missing hidden '${expected}': ${names.join(", ")}`);
    }
    // 'tools' itself answers --help without hiding, only its subcommands do;
    // seeding it as a root child would duplicate the one recursion already finds.
    assertExcludes(names.join(","), "tools");
  },

  "the dev channel seeds tools' hidden subcommands"() {
    assertEquals(hiddenChildrenFor(["tools"], "dev"), [
      "install",
      "info",
      "uninstall",
      "update",
      "list",
    ]);
  },

  "the dev channel seeds dev-call's hidden subcommands, not the one it already lists"() {
    const names = hiddenChildrenFor(["dev-call"], "dev");
    for (const expected of ["validate-yaml", "build-artifacts", "show-ast-trace", "make-ast-diagram", "pull-git-subtree", "typst-gather"]) {
      assert(names.includes(expected), `dev-call is missing hidden '${expected}': ${names.join(", ")}`);
    }
    assert(!names.includes("cli-info"), `cli-info should not be seeded: ${names.join(", ")}`);
  },

  "dev-call's own help lists only the one subcommand recursion already finds"() {
    // Documents why the other six need seeding: they are individually hidden,
    // so even dev-call's own --help does not mention them. 'help' is listed
    // too, but introspectCommand drops it before it ever reaches here.
    const { children } = parseHelp(fixture("dev-call"), ["dev-call"]);
    assertEquals(children.map((child) => child.name), ["help", "cli-info"]);
  },

  "tools' own help lists no subcommands beyond the built-in 'help'"() {
    // Every one of them is hidden, which is why hiddenChildrenFor has to seed
    // 'tools' even though 'tools' itself is a visible, ordinarily-discovered
    // command.
    const { children } = parseHelp(fixture("tools"), ["tools"]);
    assertEquals(children.map((child) => child.name), ["help"]);
  },

  "a hidden subcommand's own positional is still read from its usage line"() {
    const { command } = parseHelp(fixture("tools-install"), ["tools", "install"]);
    assertEquals(command.args.map((arg) => arg.name), ["tool"]);
  },

  "a description stops before the Arguments block Cliffy renders inside it"() {
    const { command } = parseHelp(
      fixture("dev-call-pull-git-subtree"),
      ["dev-call", "pull-git-subtree"],
    );
    assertIncludes(command.description, "Pull configured git subtrees.");
    assertExcludes(command.description, "Arguments");
    assertExcludes(command.description, "Name of subtree to pull");
  },

  "the overlay gives create-project its enums, including the one help text cannot express"() {
    const { command } = parseHelp(fixture("create-project"), ["create-project"]);
    const spec: Spec = {
      quartoVersion: "99.9.9",
      channel: "dev",
      root: { path: [], description: "", options: [], args: [], commands: [command] },
    };
    const enriched = enrich(spec).root.commands[0];
    // Harvested automatically from its parenthesised list in the description.
    assertEquals(option(enriched, "--type").kind, "enum");
    assert((option(enriched, "--type").values ?? []).includes("book"), "--type is missing book");
    // Written "(jupyter, knitr, markdown, ...)"; the trailing ellipsis stops
    // the automatic harvest, so the overlay has to state the set itself.
    assertEquals(option(enriched, "--engine").kind, "enum");
    assert(
      (option(enriched, "--engine").values ?? []).includes("julia"),
      "--engine is missing julia",
    );
    // Written "('source' or 'visual')", which the harvester's comma-separated
    // pattern does not match at all.
    assertEquals(option(enriched, "--editor").values, ["source", "visual"]);
  },

  "the dev channel needs a 99.9.9 build, and a 99.9.9 build needs the dev channel"() {
    assertEquals(assertChannelMatchesVersion("dev", kDevVersion), undefined);
    assertEquals(assertChannelMatchesVersion("stable", "1.10.18"), undefined);
    assertEquals(assertChannelMatchesVersion("prerelease", "1.11.0"), undefined);

    let message = "";
    try {
      assertChannelMatchesVersion("dev", "1.10.18");
    } catch (error) {
      message = (error as Error).message;
    }
    assertIncludes(message, "dev");
    assertIncludes(message, "1.10.18");

    message = "";
    try {
      assertChannelMatchesVersion("stable", kDevVersion);
    } catch (error) {
      message = (error as Error).message;
    }
    assertIncludes(message, kDevVersion);
    assertIncludes(message, "stable");
  },

  "a seeded description is cut to its first sentence"() {
    assertEquals(
      firstSentence("Pull configured git subtrees. This command pulls from a repository."),
      "Pull configured git subtrees.",
    );
  },

  "a seeded description with no second sentence is kept whole"() {
    assertEquals(
      firstSentence("Builds all the javascript assets necessary for IDE support."),
      "Builds all the javascript assets necessary for IDE support.",
    );
  },

  // Command names, flags, and enum values come from `quarto --help` output,
  // not from this repo, and the dev channel sources that from an unreviewed,
  // third-party branch. Empirically verified against real bash and zsh (not
  // only checked here): a crafted name run through the unfixed emitters wrote
  // a marker file the moment the generated script was sourced or completed
  // against; against the fixed ones, it never did, on both.

  "bash escapes a name that would otherwise close its double-quoted candidate list"() {
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.commands.push({
      path: ["call", 'evil"; touch pwned; echo "'],
      description: "x",
      options: [],
      args: [],
      commands: [],
    });
    const output = emitBash(enrich(spec));
    assertIncludes(output, 'evil\\"; touch pwned; echo \\"');
    assertExcludes(output, 'evil"; touch pwned; echo "');
  },

  "bash escapes a flag that would otherwise close its case pattern early"() {
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({ long: "--evil)touch pwned;(", description: "x", kind: "value" });
    const output = emitBash(enrich(spec));
    // `:::` marks where the case pattern for this flag starts; escaped there
    // is safe, since the same flag also appears unescaped and correctly so
    // in the double-quoted contexts elsewhere in the same output.
    assertIncludes(output, ":::--evil\\)touch\\ pwned\\;\\(");
    assertExcludes(output, ":::--evil)touch pwned;(");
  },

  "zsh escapes a name that would otherwise close its quoted array entry"() {
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.commands.push({
      path: ["call", "evil'; touch pwned; echo '"],
      description: "x",
      options: [],
      args: [],
      commands: [],
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "evil'\\''; touch pwned; echo '\\''");
    assertExcludes(output, "evil'; touch pwned; echo '");
  },

  "zsh escapes a name that would otherwise close its unquoted case pattern"() {
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.commands.push({
      path: ["call", "evil'; touch pwned; echo '"],
      description: "x",
      options: [],
      args: [],
      commands: [],
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "evil\\'\\;\\ touch\\ pwned\\;\\ echo\\ \\'");
  },

  "zsh escapes a flag left unquoted for brace expansion"() {
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({
      short: "-e",
      long: "--evil';touch pwned;'",
      description: "x",
      kind: "value",
    });
    const output = emitZsh(enrich(spec));
    // The trailing '=' is bareWord()'s own addition for a valued long form,
    // so it belongs in the string this excludes, or the check can never
    // match the real output either way and would pass regardless of whether
    // the escaping it is meant to guard is even present.
    assertExcludes(output, "{-e,--evil';touch pwned;'=}");
    assertIncludes(output, "\\'\\;touch\\ pwned\\;\\'");
  },

  "fish escapes a name that would otherwise close its quoted case pattern"() {
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.path = ["evil'; touch pwned; echo '"];
    render.options.push({ long: "--to", description: "x", kind: "value" });
    const output = emitFish(spec);
    assertExcludes(output, "case 'evil'; touch pwned; echo '");
  },

  "fish keeps every -n condition free of untrusted text, whatever it contains"() {
    // -n is parsed twice: once as this file is sourced, again when
    // `complete` evaluates it as a condition command, through `eval` or its
    // equivalent -- and that second pass turned out to have its own,
    // apparently undocumented rules for a backslash next to a quote,
    // different enough from ordinary fish parsing that no quoting scheme
    // tried here survived embedding path directly in the condition text: a
    // name combining the two ran a command the moment `complete` looked at
    // it, regardless of whether path was double-quoted or single-quoted
    // first. path instead sits once, as an ordinary string literal, in a
    // per-command wrapper function's body -- source parsed only when the
    // file is sourced -- and -n calls the function by its safe, sanitised
    // name. A structural check, not a pattern that can be escaped around:
    // the vulnerable shape was ever putting path in -n's own text at all.
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.commands.push({
      path: ["call", 'a\\"; touch pwned; #'],
      description: "x",
      options: [{ long: "--z", description: "d", kind: "none" }],
      args: [],
      commands: [],
    });
    const output = emitFish(spec);
    assertIncludes(output, `__quarto_at 'call a\\"; touch pwned; #' $index`);
    let checked = 0;
    for (const line of output.split("\n")) {
      if (!line.startsWith("complete -c quarto -n ")) {
        continue;
      }
      const match = /-n '([^']*)'/.exec(line);
      if (!match) {
        throw new Error(`no -n value found in: ${line}`);
      }
      assert(
        /^__quarto_is_[A-Za-z0-9_]+( \d+\+?)?$/.test(match[1]),
        `-n value is not a bare, safe function call: ${match[1]}`,
      );
      checked++;
    }
    assert(checked > 0, "no complete -n lines were found to check");
  },

  "fish routes -a candidates through a function rather than a literal list"() {
    // fish re-expands a literal -a candidate list at completion time,
    // running any (...) a candidate carries -- fish's own documented
    // mechanism for generating candidates dynamically from a command's
    // output, e.g. 'complete -a "(ls)"', applying to every word in the
    // list, not only one spelled as the whole argument. Verified against
    // real fish: a subcommand named "(touch pwned)" ran it the moment
    // `quarto <TAB>` looked at the candidate, and so did an enum value.
    // A structural check: the vulnerable shape was `-a` given anything but
    // a `(__quarto_words ...)` call.
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.commands.push({
      path: ["call", "(touch pwned)"],
      description: "x",
      options: [
        { long: "--evil-enum", description: "d", kind: "enum", values: ["a", "(touch pwned)"] },
      ],
      args: [],
      commands: [],
    });
    const output = emitFish(spec);
    assertIncludes(output, `-a "(__quarto_words '(touch pwned)')"`);
    assertIncludes(output, `-a "(__quarto_words 'a' '(touch pwned)')"`);
  },

  "zsh escapes a placeholder that would otherwise close its quoted spec"() {
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({
      long: "--evil",
      description: "x",
      kind: "value",
      placeholder: "ev'; touch pwned; echo '",
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "ev'\\''; touch pwned; echo '\\''");
    assertExcludes(output, ":ev'; touch pwned; echo ':");
  },

  "zsh escapes a colon that would otherwise end a spec label early"() {
    // A spec label reads up to the next unescaped ':' as one field; an
    // unescaped one inside it starts a fresh field early, which can be a
    // {...} eval-string action. Verified against real zsh: a placeholder
    // carrying ':{touch pwned}' ran a command the moment it was offered.
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({
      long: "--evil-ph",
      description: "x",
      kind: "value",
      placeholder: "pl:{touch pwned}",
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "pl\\:{touch pwned}");
    assertExcludes(output, ":pl:{touch pwned}:");
  },

  "zsh escapes a colon in a subcommand name the same way"() {
    const spec = fixtureSpec();
    const call = spec.root.commands.find((command) => command.path[0] === "call")!;
    call.commands.push({
      path: ["call", "evil:{touch pwned}"],
      description: "x",
      options: [],
      args: [],
      commands: [],
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "evil\\:{touch pwned}:x");
    assertExcludes(output, "'evil:{touch pwned}:x'");
  },

  "zsh routes enum values through a function rather than a literal action list"() {
    // _arguments re-evaluates a literal (a b) action list at completion time,
    // running a $(...) or `...` an enum value carries; verified against real
    // zsh. Values must reach compadd as arguments to a call instead, which is
    // not re-evaluated the same way, so this is a structural check, not a
    // pattern that can be escaped around: the vulnerable shape was `(a
    // $(touch pwned))`, whatever quoting surrounded it.
    const spec = fixtureSpec();
    const render = spec.root.commands[0];
    render.options.push({
      long: "--evil-enum",
      description: "x",
      kind: "enum",
      values: ["a", "$(touch pwned)"],
    });
    const output = emitZsh(enrich(spec));
    assertIncludes(output, "_quarto_enum '\\''a'\\'' '\\''$(touch pwned)'\\'''");
    assertExcludes(output, "(a $(touch pwned))");
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
