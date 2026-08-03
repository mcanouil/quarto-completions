# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Static shell completions for the Quarto CLI, covering bash, zsh, fish, and PowerShell.
  Every candidate is baked into the script, so nothing runs Quarto while you type.
- A generator that reads `quarto --help` recursively and emits all four scripts, run with `quarto run src/generate.ts`.
- Value completion for output formats, log levels, publishing providers, installable tools, `check` targets, rendering engines, and the Pandoc options Quarto forwards.
- Input positionals filtered to the documents Quarto renders: `.qmd`, `.ipynb`, `.md`, and `.Rmd`.
- One-line installers for POSIX shells and PowerShell, with SHA-256 verification, an idempotent managed block, `--dry-run`, and `--uninstall`.
- `stable` and `prerelease` channels, published from the documentation website along with a manifest of checksums.
