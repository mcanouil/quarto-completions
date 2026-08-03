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

import type { OptionSpec, ValueKind } from "./spec.ts";

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
const kPandocOptions: OptionSpec[] = [
  { long: "--toc", description: "Include an automatically generated table of contents.", kind: "none" },
  { long: "--toc-depth", description: "Number of section levels in the table of contents.", kind: "value" },
  { long: "--number-sections", description: "Number section headings.", kind: "none" },
  { long: "--number-offset", description: "Offset for section headings.", kind: "value" },
  {
    long: "--top-level-division",
    description: "Treat top-level headings as this division.",
    kind: "enum",
    values: ["default", "section", "chapter", "part"],
  },
  { long: "--standalone", description: "Produce a standalone document.", kind: "none" },
  { long: "--template", description: "Use FILE as a custom template.", kind: "file" },
  { long: "--css", description: "Link to a CSS style sheet.", kind: "file", globs: ["css"] },
  {
    long: "--bibliography",
    description: "Bibliography file.",
    kind: "file",
    globs: ["bib", "bibtex", "json", "yml", "yaml"],
  },
  { long: "--csl", description: "Citation Style Language file.", kind: "file", globs: ["csl"] },
  { long: "--citeproc", description: "Process citations with citeproc.", kind: "none" },
  { long: "--highlight-style", description: "Syntax highlighting style.", kind: "value" },
  {
    long: "--pdf-engine",
    description: "Engine used to produce PDF output.",
    kind: "enum",
    values: ["pdflatex", "lualatex", "xelatex", "tectonic", "latexmk", "context", "wkhtmltopdf", "weasyprint", "typst"],
  },
  { long: "--mathjax", description: "Render mathematics with MathJax.", kind: "none" },
  { long: "--katex", description: "Render mathematics with KaTeX.", kind: "none" },
  {
    long: "--wrap",
    description: "Text wrapping in the output.",
    kind: "enum",
    values: ["auto", "none", "preserve"],
  },
  {
    long: "--reference-doc",
    description: "Reference document for docx, pptx, or odt output.",
    kind: "file",
    globs: ["docx", "pptx", "odt"],
  },
  { long: "--shift-heading-level-by", description: "Shift heading levels by this amount.", kind: "value" },
];

/** How a flag or positional is completed, when help output cannot say. */
interface ValueOverride {
  kind: ValueKind;
  values?: string[];
  globs?: string[];
}

interface CommandOverride {
  /** Keyed by any flag form, long preferred. */
  options?: Record<string, ValueOverride>;
  /** Keyed by the positional name used in the usage line. */
  args?: Record<string, ValueOverride>;
  /** Flags the command accepts and forwards, but does not declare. */
  extraOptions?: OptionSpec[];
}

export const overlay: Record<string, CommandOverride> = {
  "*": {
    options: {
      "--log": { kind: "file" },
      "--profile": { kind: "value" },
    },
  },
  "render": {
    extraOptions: kPandocOptions,
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
    extraOptions: kPandocOptions,
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

/**
 * Overrides for one command, with the wildcard entry merged in. Extra options
 * are read from the command's own entry only: the wildcard applies to every
 * command, and no flag is forwarded by all of them.
 */
export function overrideFor(
  path: string[],
): Required<Pick<CommandOverride, "options" | "args">> & Pick<CommandOverride, "extraOptions"> {
  const wildcard = overlay["*"] ?? {};
  const specific = overlay[path.join(" ")] ?? {};
  return {
    options: { ...wildcard.options, ...specific.options },
    args: { ...wildcard.args, ...specific.args },
    extraOptions: specific.extraOptions,
  };
}

/**
 * Merges an override into a flag or a positional. Both carry the same three
 * completion fields, so one function serves both.
 */
export function applyOverride<T extends Pick<OptionSpec, "kind" | "values" | "globs">>(
  target: T,
  override?: ValueOverride,
): T {
  if (!override) {
    return target;
  }
  return {
    ...target,
    kind: override.kind,
    values: override.values ?? target.values,
    globs: override.globs ?? target.globs,
  };
}
