/**
 * Value semantics that `quarto --help` does not express.
 *
 * Most Quarto commands declare their options with Cliffy but without a value
 * type, because they parse their own arguments and forward the rest (`render`
 * is declared with `.stopEarly()`, for instance). Help output therefore shows
 * `-t, --to` exactly as it shows `--cache-refresh`, even though the first takes
 * a format and the second is a switch. Anything a completion needs to know
 * beyond the flag's existence is declared here.
 *
 * Keys are command paths joined by a space, with the empty string for the root.
 * `"*"` applies to every command, and is how the global logging and profile
 * options are described once.
 */

import type { ArgSpec, OptionSpec, ValueKind } from "./spec.ts";

/** Input documents Quarto renders. */
const kInputGlobs = ["qmd", "ipynb", "md", "Rmd", "rmd", "markdown"];

/** Built-in output formats accepted by `--to`. */
const kFormats = [
  "html",
  "pdf",
  "docx",
  "odt",
  "rtf",
  "revealjs",
  "beamer",
  "pptx",
  "typst",
  "dashboard",
  "epub",
  "gfm",
  "commonmark",
  "markdown",
  "markua",
  "hugo-md",
  "docusaurus-md",
  "jats",
  "asciidoc",
  "asciidoctor",
  "ipynb",
  "context",
  "docbook",
  "dokuwiki",
  "jira",
  "mediawiki",
  "man",
  "ms",
  "muse",
  "opml",
  "org",
  "rst",
  "texinfo",
  "textile",
  "xwiki",
  "zimwiki",
];

/** Global dependencies `install`, `uninstall`, and `update` accept. */
const kTools = ["tinytex", "chrome-headless-shell", "verapdf"];

/** Providers `publish` accepts, as slugged in its help description. */
const kPublishProviders = [
  "quarto-pub",
  "gh-pages",
  "connect",
  "posit-connect-cloud",
  "netlify",
  "confluence",
  "huggingface",
];

/**
 * Pandoc options Quarto forwards from `render` and `preview`. Without these,
 * pressing TAB after `quarto render doc.qmd --` offers nothing beyond Quarto's
 * own flags, even though every one of these is accepted.
 */
const kPandocPassthrough: Record<string, { description: string; kind: ValueKind; values?: string[] }> = {
  "--toc": { description: "Include an automatically generated table of contents.", kind: "none" },
  "--toc-depth": { description: "Number of section levels in the table of contents.", kind: "value" },
  "--number-sections": { description: "Number section headings.", kind: "none" },
  "--number-offset": { description: "Offset for section headings.", kind: "value" },
  "--top-level-division": {
    description: "Treat top-level headings as this division.",
    kind: "enum",
    values: ["default", "section", "chapter", "part"],
  },
  "--standalone": { description: "Produce a standalone document.", kind: "none" },
  "--template": { description: "Use FILE as a custom template.", kind: "file" },
  "--css": { description: "Link to a CSS style sheet.", kind: "file" },
  "--bibliography": { description: "Bibliography file.", kind: "file" },
  "--csl": { description: "Citation Style Language file.", kind: "file" },
  "--citeproc": { description: "Process citations with citeproc.", kind: "none" },
  "--highlight-style": { description: "Syntax highlighting style.", kind: "value" },
  "--pdf-engine": {
    description: "Engine used to produce PDF output.",
    kind: "enum",
    values: ["pdflatex", "lualatex", "xelatex", "tectonic", "latexmk", "context", "wkhtmltopdf", "weasyprint", "typst"],
  },
  "--mathjax": { description: "Render mathematics with MathJax.", kind: "none" },
  "--katex": { description: "Render mathematics with KaTeX.", kind: "none" },
  "--wrap": {
    description: "Text wrapping in the output.",
    kind: "enum",
    values: ["auto", "none", "preserve"],
  },
  "--reference-doc": { description: "Reference document for docx, pptx, or odt output.", kind: "file" },
  "--shift-heading-level-by": { description: "Shift heading levels by this amount.", kind: "value" },
};

interface OptionOverride {
  kind: ValueKind;
  values?: string[];
  globs?: string[];
}

interface CommandOverride {
  /** Keyed by any flag form, long preferred. */
  options?: Record<string, OptionOverride>;
  /** Keyed by the positional name used in the usage line. */
  args?: Record<string, OptionOverride>;
  /** Extra flags Quarto forwards but does not declare. */
  passthrough?: "pandoc";
}

export const overlay: Record<string, CommandOverride> = {
  "*": {
    options: {
      "--log": { kind: "file" },
      "--profile": { kind: "value" },
    },
  },
  "": {
    options: {},
  },
  "render": {
    passthrough: "pandoc",
    options: {
      "--to": { kind: "enum", values: kFormats },
      "--output": { kind: "file" },
      "--output-dir": { kind: "dir" },
      "--metadata": { kind: "value" },
      "--site-url": { kind: "value" },
      "--execute-param": { kind: "value" },
      "--execute-params": { kind: "file", globs: ["yml", "yaml", "json"] },
      "--execute-dir": { kind: "dir" },
      "--execute-daemon": { kind: "value" },
    },
    args: {
      input: { kind: "file", globs: kInputGlobs },
    },
  },
  "preview": {
    passthrough: "pandoc",
    options: {
      "--port": { kind: "value" },
      "--host": { kind: "value" },
      "--render": { kind: "enum", values: ["all", ...kFormats] },
      "--timeout": { kind: "value" },
    },
    args: {
      file: { kind: "file", globs: kInputGlobs },
    },
  },
  "serve": {
    options: {
      "--port": { kind: "value" },
      "--host": { kind: "value" },
    },
    args: {
      input: { kind: "file", globs: kInputGlobs },
    },
  },
  "create": {
    args: {
      type: { kind: "enum", values: ["project", "extension"] },
    },
  },
  // `use` needs no positional overlay: `template`, `binder`, and `brand` are
  // real subcommands, and completing them twice would duplicate every
  // candidate.
  "convert": {
    options: {
      "--output": { kind: "file" },
    },
    args: {
      input: { kind: "file", globs: kInputGlobs },
    },
  },
  "run": {
    args: {
      script: { kind: "file", globs: ["ts", "js", "py", "R", "r", "lua"] },
    },
  },
  "list": {
    args: {
      type: { kind: "enum", values: ["extensions", "tools"] },
    },
  },
  "install": {
    args: {
      target: { kind: "enum", values: kTools },
    },
  },
  "uninstall": {
    args: {
      tool: { kind: "enum", values: kTools },
    },
  },
  "update": {
    args: {
      target: { kind: "enum", values: kTools },
    },
  },
  "publish": {
    args: {
      provider: { kind: "enum", values: kPublishProviders },
      path: { kind: "file", globs: kInputGlobs },
    },
  },
  "check": {
    options: {
      "--output": { kind: "file" },
    },
    args: {
      target: { kind: "enum", values: ["install", "jupyter", "knitr", "versions", "all"] },
    },
  },
  "call engine": {
    args: {
      "engine-name": { kind: "enum", values: ["jupyter", "knitr", "markdown", "julia"] },
    },
  },
  "call build-ts-extension": {
    args: {
      "entry-point": { kind: "file", globs: ["ts"] },
    },
  },
};

/** Overrides for one command, with the wildcard entry merged in. */
export function overrideFor(path: string[]): CommandOverride {
  const wildcard = overlay["*"] ?? {};
  const specific = overlay[path.join(" ")] ?? {};
  return {
    options: { ...wildcard.options, ...specific.options },
    args: { ...wildcard.args, ...specific.args },
    passthrough: specific.passthrough ?? wildcard.passthrough,
  };
}

export function applyOptionOverride(option: OptionSpec, override?: OptionOverride): OptionSpec {
  if (!override) {
    return option;
  }
  return {
    ...option,
    kind: override.kind,
    values: override.values ?? option.values,
    globs: override.globs ?? option.globs,
  };
}

export function applyArgOverride(arg: ArgSpec, override?: OptionOverride): ArgSpec {
  if (!override) {
    return arg;
  }
  return {
    ...arg,
    kind: override.kind,
    values: override.values ?? arg.values,
    globs: override.globs ?? arg.globs,
  };
}

/** Pandoc options forwarded by the commands that declare a passthrough. */
export function passthroughOptions(): OptionSpec[] {
  return Object.entries(kPandocPassthrough).map(([long, spec]) => ({
    long,
    description: spec.description,
    kind: spec.kind,
    values: spec.values,
  }));
}
