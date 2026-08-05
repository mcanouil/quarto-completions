# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Bug Fixes

- fix: drop the `1.6`, `1.7`, and `1.8` archived channels; per-minor archives now start at `1.9`.
  The generator's parser and `src/overlay.ts`'s hardcoded value sets are only exercised against recent Quarto releases; the further back an archived minor goes, the less confidence there is that an old `--help` layout is read correctly, so the floor is pulled in until that is verified further back.

## 2026.08.05-2 (2026-08-05)

### Install

macOS and Linux:

```bash
curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash
```

Windows:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://m.canouil.dev/quarto-completions/install.ps1 | iex"
```

### New Features

- feat: publish an archived channel for every Quarto minor from `1.6` onward, generated from that line's newest patch.
  With no `--channel` given, the installer matches the local Quarto's own minor when it is published, falling back to `release`; the most recently archived minor is refreshed weekly against a late patch, and older ones are frozen.

### Breaking Changes

- feat!: rename the `stable` and `prerelease` channels to `release` and `pre-release`, matching the vocabulary `quarto-actions/setup` already uses.
  `--channel stable` and `--channel prerelease`, and the `completions/stable/` and `completions/prerelease/` URLs, no longer resolve; the piped installers are unaffected, since they always fetch fresh.

## 2026.08.05 (2026-08-05)

### New Features

- feat: complete Quarto CLI commands and flags in bash, zsh, fish, and PowerShell.
  Every candidate is baked into the script, so pressing Tab runs no process, where the completions Quarto ships behind a hidden command spawn a cold Quarto start on every keypress and return nothing for options declared without a value type.
- feat: complete values, not only flag names: output formats for `--to`, log levels, publishing providers, installable tools, `check` targets, rendering engines, and the Pandoc options Quarto forwards from `render` and `preview`.
  Attached and spaced spellings both work, so `quarto render --to=html` completes like `quarto render --to html`.
- feat: filter input positionals to `.qmd`, `.ipynb`, `.md`, `.Rmd`, and `.markdown` alongside directories, tracking positional slots so `quarto publish gh-pages` offers a path rather than a second provider.
- feat: install with one line, `curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash` on macOS and Linux and `powershell -ExecutionPolicy ByPass -c "irm https://m.canouil.dev/quarto-completions/install.ps1 | iex"` on Windows.
  Both write under the user's home directory, never call `sudo`, verify each file against the published SHA-256 before writing, and support `--dry-run`, `--uninstall`, and `--help`.
- feat: keep every shell configuration edit inside a managed block that re-running replaces and `--uninstall` removes.
  A block whose closing marker is missing is refused rather than rewritten, on install, on uninstall, and in `--dry-run` alike; an rc file that is a symlink stays a symlink, and a PowerShell profile carrying no block is left byte-identical.
- feat: write each shell's file where that shell will actually find it: `$XDG_DATA_HOME/bash-completion/completions` for bash where it exists, `$ZSH_CUSTOM/completions` under Oh My Zsh, Homebrew's `share/zsh/site-functions` where the prefix has one and it is writable, `~/.zfunc` otherwise, and fish's autoloaded completions directory.
  The first three need no configuration at all.
- feat: keep a later install where the first one landed, so installing Oh My Zsh, Homebrew, or `bash-completion` afterwards updates the copy already on disk rather than moving it.
  The other known locations are swept so nothing shadows it, and a stale copy that cannot be removed, such as one in a Homebrew prefix owned by another user, is reported rather than fatal.
- feat: leave an unchanged script alone.
  The published manifest is enough to tell that the installed file is already the one that would be written, so re-running over an unchanged release reports `Already current` and downloads nothing.
- feat: publish a `stable` and a `prerelease` channel, generated from the two Quarto release channels, each with a manifest carrying the Quarto version and a checksum per file.
- feat: publish a third `dev` channel, generated from a Quarto source build, completing the commands Quarto hides from `quarto --help`: `dev-call` and its subcommands, `inspect`, `capabilities`, `create-project`, `editor-support`, `completions`, and every subcommand of `tools`.
  Hidden commands cannot be found by walking help output, so they are seeded by path and introspected directly; both installers select this channel automatically when the `quarto` on `PATH` reports version `99.9.9`, which is what a source build reports and a release never does.
- feat: warn when the `quarto` on `PATH` does not match the completions being installed.
  Both installers compare major and minor versions only; a patch difference, the `dev` sentinel, or no `quarto` on `PATH` says nothing, and the install always succeeds.
- feat: end an install by naming a command that loads what was just written: `exec bash` rather than `exec bash -l`, because a login bash reads `~/.bash_profile`, `~/.bash_login`, or `~/.profile` and never falls back to the `~/.bashrc` the block goes in.
  Where none of those exists, the default on macOS, or the first one bash finds never mentions `.bashrc`, the install says so and gives the line that fixes it rather than writing anything itself.
- feat: report the shells an install is not maintaining, since each run maintains only the shell `$SHELL` names.
  The version and channel stamped in every generated script is read back from whatever is installed for the other shells, and a mismatch is named along with the command that updates it; a file carrying no stamp, or one that cannot be read, is left alone.
- feat: generate the scripts by walking `quarto <command> --help` over the whole command tree, run with `quarto run src/generate.ts`.
  The generator uses Quarto's own embedded runtime, so an installed Quarto is its only dependency, and `--check` fails when the committed output is stale.

### Documentation

- docs: add a documentation website at <https://m.canouil.dev/quarto-completions>, covering installation, the file and configuration each shell needs, the channels, and troubleshooting.
- docs: give the website its own identity on the `atelier` project type: a terminal-green palette that follows the light and dark colour schemes, a mark derived from the Quarto quadrant with the fourth pane left for Tab to complete, and the favicon, touch icon, web app manifest, and social card generated from it.
  Code blocks carry window chrome naming the shell, the navbar links to issues, discussions, and releases through a repository widget, and a 404 page replaces the server default.
- docs: add a security policy covering how to report a vulnerability, what is in scope, and the trust boundaries that are design limits rather than bugs.
