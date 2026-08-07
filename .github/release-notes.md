## Install

macOS and Linux:

```bash
curl -fsSL https://m.canouil.dev/quarto-completions/install.sh | bash
```

Windows:

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://m.canouil.dev/quarto-completions/install.ps1 | iex"
```

Both installers always download the latest published completions rather than anything pinned to this release. See <https://m.canouil.dev/quarto-completions>.

To install offline, or to pin this release, download `quarto-completions-%%VERSION%%.tar.gz` or `quarto-completions-%%VERSION%%.zip` below.
Each holds one directory per channel, with the `manifest.json` carrying the SHA-256 of every file beside it.
