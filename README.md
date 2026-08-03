# Quarto Completions

Shell completions for the [Quarto CLI](https://quarto.org): bash, zsh, fish, and PowerShell.

Press <kbd>Tab</kbd> and get Quarto's commands, flags, output formats, log levels, and publishing providers, with input documents filtered to the ones Quarto can render.
The scripts are generated ahead of time and contain every candidate, so nothing runs Quarto while you type.

Documentation: <https://m.canouil.dev/quarto-completions>.

## Install

macOS and Linux:

```bash
curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash
```

Windows:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://m.canouil.dev/quarto-completions/install.ps1 | iex"
```

The shell is detected from `$SHELL`; pass `--shell bash|zsh|fish` to override it.
Everything is written under your home directory, and nothing needs root.
Add `--dry-run` to see the paths first, or `--uninstall` to remove it all.

## How it works

`src/generate.ts` runs `quarto <command> --help` over the whole command tree, parses the result into a spec, enriches it with the value semantics that help output cannot express (`src/overlay.ts`), and emits one script per shell.
The generator runs on Quarto's own embedded runtime, so a Quarto installation is its only dependency:

```bash
quarto run src/generate.ts                    # regenerate docs/completions/
quarto run src/generate.ts --check            # fail if the committed output is stale
quarto run src/generate.ts --channel prerelease
```

Generated scripts, the installers, and the documentation website all live under `docs/`, which is what GitHub Pages publishes.

## Tests

```bash
quarto run tests/run.ts        # parser and emitter tests, against captured help fixtures
bash tests/syntax.sh           # parse each script with its own shell, lint the installers
bash tests/completions.sh      # drive real completion in each shell and assert candidates
quarto render docs             # build the site
bash tests/install.sh          # install, re-install, and uninstall against a local server
pwsh -NoProfile -File tests/install.ps1   # the same, for the PowerShell installer
```

Each script reports a shell it cannot find as skipped, so a machine without fish or PowerShell still runs everything else.
The full matrix runs on Linux, macOS, and Windows in CI.

## Limitations

- Formats and shortcodes contributed by installed extensions are not completed: reading them would mean running Quarto on every keystroke.
- Hidden developer commands such as `quarto dev-call` are excluded, as they are from `quarto --help`.

## Licence

MIT. See [LICENSE](LICENSE).
