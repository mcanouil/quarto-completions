# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### New Features

- feat: complete Quarto CLI commands and flags in bash, zsh, fish, and PowerShell. Every candidate is baked into the script, so pressing Tab runs no process; the completions Quarto ships behind a hidden command spawn a cold Quarto start on every keypress and return nothing for options declared without a value type.
- feat: complete values, not only flag names: output formats for `--to`, log levels, publishing providers, installable tools, `check` targets, rendering engines, and the Pandoc options Quarto forwards from `render` and `preview`.
- feat: filter input positionals to the documents Quarto renders, meaning `.qmd`, `.ipynb`, `.md`, and `.Rmd`, alongside directories. Positional slots are tracked, so `quarto publish gh-pages` offers a path rather than a second provider.
- feat: install with one line, `curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash` on macOS and Linux and `irm https://m.canouil.dev/quarto-completions/install.ps1 | iex` on Windows. Both write under the user's home directory, need no elevation, verify each download against the published SHA-256, and keep any shell configuration edit inside a managed block that re-running replaces and `--uninstall` removes.
- feat: install zsh completions into Homebrew's own `share/zsh/site-functions` when the prefix has one and it is writable. Homebrew's shell setup already puts that directory on `fpath`, so nothing is added to `~/.zshrc`. The prefix is read from `$HOMEBREW_PREFIX`, or found at `/opt/homebrew` or `/usr/local`, rather than by running `brew`, which a `curl | bash` pipe often cannot reach.
- feat: leave an unchanged script alone. The published manifest is enough to tell that the installed file is already the one that would be written, so re-running over an unchanged release reports `Already current` and downloads nothing.
- feat: publish a `stable` and a `prerelease` channel, generated from the two Quarto release channels, each with a manifest carrying the Quarto version and a checksum per file.
- feat: generate the scripts by walking `quarto <command> --help` over the whole command tree, run with `quarto run src/generate.ts`. The generator uses Quarto's own embedded runtime, so an installed Quarto is its only dependency.
- feat: publish a third `dev` channel, generated from a Quarto source build, completing the commands Quarto hides from `quarto --help`: `dev-call` and its subcommands, `inspect`, `capabilities`, `create-project`, `completions`, and every subcommand of `tools`. Hidden commands cannot be discovered by walking help output, so they are seeded by path and introspected directly, only when the channel is `dev`. Both installers select this channel automatically, with no flag needed, when the `quarto` on `PATH` reports version `99.9.9`, which is what a source build reports and a release never does.

### Bug Fixes

- fix: complete a value attached to its flag, so `quarto render --to=html` works in bash and zsh as well as spelled with a space. bash splits words on `=` and `:`, so the attached form counted its pieces as positionals and offered files where formats belong, and a metadata value written `key:value` pushed every later positional off its slot; the words are now glued back together before anything reads them. zsh option specs carry a trailing `=` on valued long options, which `_arguments` reads as accepting both forms.
- fix: filter fish file candidates on every fish version. fish only accepts several suffixes in one `__fish_complete_suffix` call from 3.6 on; older versions read the second argument as the token to complete, which silently broke the filter to renderable documents. Each suffix is now a call of its own.
- fix: keep a symlinked shell configuration a symlink. Rewriting the managed block replaced an rc file that was a symlink into a dotfiles checkout with a plain file in mktemp's 0600 mode; the block is now written back through the existing file.
- fix: fall through when an earlier install can no longer be written. A completion script found in a directory that has since become read-only, such as a Homebrew prefix owned by another user, was chosen again and the install died after the download; it now lands in a writable location and reports the copy it could not remove.
- fix: name the rc file when it cannot be written, on the first install and on every later rewrite, rather than stopping with a bare permission error from the shell.
- fix: refuse an unknown channel arriving through `QUARTO_COMPLETIONS_CHANNEL` in the PowerShell installer with a clear message; it previously surfaced later as a confusing download error.

- fix: install zsh completions where Oh My Zsh will find them. Oh My Zsh puts `$ZSH_CUSTOM/completions` on `fpath` and runs `compinit` itself while `~/.zshrc` is still sourcing it, so a block appended below that ran too late and the completions never loaded. The file now goes straight there, and no shell configuration is edited.
- fix: use `compinit -i` rather than `compinit -C` in the managed block. `-C` omits the check for new completion functions and reuses the existing dump, so on any machine where `compinit` had already run, the newly installed `_quarto` was never picked up.
- fix: remove what an earlier run left behind. The installer only ever cleaned the one location that suited the machine at the time, so a script written anywhere else was stranded, and its managed block with it. Installing and uninstalling now sweep every location the installer knows, and `--dry-run` reports them.
- fix: report a stale copy that cannot be removed, rather than failing on it. One of the places swept is Homebrew's prefix, which is outside the home directory and may belong to another user, and a file there is not reason enough to fail an install that has otherwise worked. Nothing is ever removed with `sudo`.
- fix: keep an install where it is. The destination was resolved from the machine's layout on every run, so installing Oh My Zsh, Homebrew, or `bash-completion` afterwards moved a file the user may have put somewhere deliberately. An install already on disk is now the one that is updated, wherever it is, and moving it is `--uninstall` followed by a fresh install.
- fix: write zsh completions to `~/.zfunc` rather than `$XDG_DATA_HOME/zsh/site-functions` when neither Oh My Zsh nor Homebrew applies. Neither directory is on zsh's default `fpath`, so both need the same managed block; `~/.zfunc` is the name the surrounding ecosystem already documents. A file left in the old directory is found and swept.

### Documentation

- docs: add a documentation website at <https://m.canouil.dev/quarto-completions>, covering installation, the file and configuration each shell needs, and troubleshooting.
- docs: give the website its own identity, built on the `atelier` project type: a terminal-green palette that follows the light and dark colour schemes, a mark derived from the Quarto quadrant with the fourth pane left for Tab to complete, and the favicon, touch icon, web app manifest, and social card generated from it. Code blocks carry window chrome naming the shell, the navbar links to issues, discussions, and releases through a repository widget, and a 404 page replaces the server default.
