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

The macOS and Linux installer detects the shell from `$SHELL`; pass `--shell bash|zsh|fish` to override it.
The Windows installer takes no such option, since PowerShell is the only shell it serves.
Everything is written under your home directory, apart from zsh on a machine with Homebrew, where the file goes in the prefix's own completions directory; nothing needs root, and nothing is written with `sudo`.
Each file is checked against the SHA-256 published in the channel's `manifest.json` before it is written, and any shell configuration edit is kept inside a managed block that re-running replaces.
Add `--dry-run` to see the paths first, `--uninstall` to remove that shell's install, or `--help` for the full list; repeat with `--shell` for each shell you installed.
If the `quarto` on your `PATH` does not match the completions being installed, the installer says so.
That check only runs when the installer does, so re-run it after upgrading Quarto; see [Troubleshooting](https://m.canouil.dev/quarto-completions/troubleshooting.html#the-completions-are-out-of-date).

## How it works

`src/generate.ts` runs `quarto <command> --help` over the whole command tree, parses the result into a spec, enriches it with the value semantics that help output cannot express (`src/overlay.ts`), and emits one script per shell.
The generator runs on Quarto's own embedded runtime, so a Quarto installation is its only dependency:

```bash
quarto run src/generate.ts                    # regenerate docs/completions/
quarto run src/generate.ts --check            # fail if the committed output is stale
quarto run src/generate.ts --channel pre-release
quarto run src/generate.ts --channel dev --quarto /path/to/a/99.9.9/build/quarto
quarto run src/generate.ts --channel 1.9 --quarto /path/to/a/1.9.x/build/quarto
```

Each channel also publishes `spec.json`, the enriched command surface the emitters read, alongside `manifest.json` and the four scripts.
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
- Commands Quarto hides from `quarto --help`, such as `dev-call`, are excluded from the `release`, `pre-release`, and per-minor channels for the same reason they are excluded from that help output. They are completed on a separate `dev` channel instead, generated from a Quarto source build and selected automatically when the `quarto` on `PATH` reports version `99.9.9`. See [Channels](https://m.canouil.dev/quarto-completions/shells.html#channels).
- An archived per-minor channel reads flags, commands, and arguments from that old Quarto's own `--help`, but a handful of value sets `src/overlay.ts` cannot read that way, such as `--to`'s output formats, come from the current Quarto instead, so an archive can occasionally offer a value its own Quarto does not accept.

## Licence

This project is licensed under the MIT License.
See the [LICENSE](LICENSE) file for details.

## Disclaimer

This extension is not affiliated with or endorsed by [Quarto](https://quarto.org) or its maintainers.
