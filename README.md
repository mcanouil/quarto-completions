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

The macOS and Linux installer detects the shell from `$SHELL`.
Pass `--shell bash|zsh|fish` to override it.
The Windows installer takes no such option, because PowerShell is the only shell it serves.
Everything is written under your home directory, apart from zsh on a machine with Homebrew, where the file goes in the prefix's own completions directory.
Nothing needs root, and nothing is written with `sudo`.
Each file is checked against the SHA-256 published in the channel's `manifest.json` before it is written.
Any shell configuration edit is kept inside a managed block that re-running replaces.
Add `--dry-run` to see the paths first, `--uninstall` to remove that shell's install, or `--help` for the full list.
Repeat with `--shell` for each shell you installed.
If the `quarto` on your `PATH` does not match the completions being installed, the installer says so.
That check only runs when the installer does, so re-run it after upgrading Quarto.
See [Troubleshooting](https://m.canouil.dev/quarto-completions/troubleshooting.html#the-completions-are-out-of-date).

## How it works

`src/generate.ts` runs `quarto <command> --help` over the whole command tree.
It parses the result into a spec, adds the value semantics that help output cannot express (`src/overlay.ts`), and emits one script per shell.
The generator runs on Quarto's own embedded runtime, so a Quarto installation is its only dependency:

```bash
quarto run src/generate.ts                    # regenerate docs/completions/
quarto run src/generate.ts --check            # fail if the committed output is stale
quarto run src/generate.ts --channel pre-release
quarto run src/generate.ts --channel dev --quarto /path/to/a/99.9.9/build/quarto
quarto run src/generate.ts --channel 1.9 --quarto /path/to/a/1.9.x/build/quarto
quarto run src/generate.ts --channel dev --quarto /path/to/a/99.9.9/build/quarto \
  --source-branch main --source-commit "$(git -C /path/to/quarto-cli rev-parse HEAD)"
```

`--source-branch` and `--source-commit` name the `quarto-dev/quarto-cli` build behind a `dev` run.
This is the one channel whose version says nothing, because every source build reports `99.9.9`.
Both flags are written to `spec.json` and `manifest.json`, and stamped into each script's header.
So `--check` on `dev` needs the same two flags to compare against what was committed.
A released channel takes neither flag.
Its tag is its version with a `v` in front of it, and the generator writes that itself.

Each channel also publishes `spec.json`, the enriched command surface the emitters read, alongside `manifest.json` and the four scripts.
Generated scripts, the installers, and the documentation website all live under `docs/`.
GitHub Pages publishes that directory.

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

- Formats and shortcodes contributed by installed extensions are not completed. Reading them needs Quarto to run on every keystroke.
- Commands Quarto hides from `quarto --help`, such as `dev-call`, are excluded from the `release`, `pre-release`, and per-minor channels. That help output excludes them for the same reason. They are completed on a separate `dev` channel instead, generated from a Quarto source build. The installer selects that channel on its own, when the `quarto` on `PATH` reports version `99.9.9`. See [Channels](https://m.canouil.dev/quarto-completions/shells.html#channels).
- A per-minor channel reads flags, commands, and arguments from that line's own `--help`. A handful of value sets, such as `--to`'s output formats, come from the current Quarto instead, because `src/overlay.ts` cannot read them from `--help`. So an older minor can occasionally offer a value its own Quarto does not accept.

## Licence

This project is licensed under the MIT License.
See the [LICENSE](LICENSE) file for details.

## Disclaimer

This extension is not affiliated with or endorsed by [Quarto](https://quarto.org) or its maintainers.
