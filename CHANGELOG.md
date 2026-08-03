# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### New Features

- feat: complete Quarto CLI commands and flags in bash, zsh, fish, and PowerShell. Every candidate is baked into the script, so pressing Tab runs no process; the completions Quarto ships behind a hidden command spawn a cold Quarto start on every keypress and return nothing for options declared without a value type.
- feat: complete values, not only flag names: output formats for `--to`, log levels, publishing providers, installable tools, `check` targets, rendering engines, and the Pandoc options Quarto forwards from `render` and `preview`.
- feat: filter input positionals to the documents Quarto renders, meaning `.qmd`, `.ipynb`, `.md`, and `.Rmd`, alongside directories. Positional slots are tracked, so `quarto publish gh-pages` offers a path rather than a second provider.
- feat: install with one line, `curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash` on macOS and Linux and `irm https://m.canouil.dev/quarto-completions/install.ps1 | iex` on Windows. Both write under the user's home directory, need no elevation, verify each download against the published SHA-256, and keep any shell configuration edit inside a managed block that re-running replaces and `--uninstall` removes.
- feat: publish a `stable` and a `prerelease` channel, generated from the two Quarto release channels, each with a manifest carrying the Quarto version and a checksum per file.
- feat: generate the scripts by walking `quarto <command> --help` over the whole command tree, run with `quarto run src/generate.ts`. The generator uses Quarto's own embedded runtime, so an installed Quarto is its only dependency.

### Bug Fixes

- fix: install zsh completions where Oh My Zsh will find them. Oh My Zsh puts `$ZSH_CUSTOM/completions` on `fpath` and runs `compinit` itself while `~/.zshrc` is still sourcing it, so a block appended below that ran too late and the completions never loaded. The file now goes straight there, and no shell configuration is edited.
- fix: use `compinit -i` rather than `compinit -C` in the managed block. `-C` omits the check for new completion functions and reuses the existing dump, so on any machine where `compinit` had already run, the newly installed `_quarto` was never picked up.
- fix: remove what an earlier run left behind. The installer wrote to whichever location suited the machine at the time and only ever cleaned that one, so installing `bash-completion` or Oh My Zsh afterwards stranded the previous script, and its managed block with it. Installing and uninstalling now sweep every location the installer has ever used, and `--dry-run` reports them.

### Documentation

- docs: add a documentation website at <https://m.canouil.dev/quarto-completions>, covering installation, the file and configuration each shell needs, and troubleshooting.
- docs: give the website its own identity, built on the `atelier` project type: a terminal-green palette that follows the light and dark colour schemes, a mark derived from the Quarto quadrant with the fourth pane left for Tab to complete, and the favicon, touch icon, web app manifest, and social card generated from it. Code blocks carry window chrome naming the shell, the navbar links to issues, discussions, and releases through a repository widget, and a 404 page replaces the server default.
