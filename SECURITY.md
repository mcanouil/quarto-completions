# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub Security Advisories: <https://github.com/mcanouil/quarto-completions/security/advisories/new>.

Please do not open a public issue for a security report.

Expect an acknowledgement within a week.
Once a fix is published, you will be credited in the advisory unless you ask otherwise.

## Scope

This project publishes shell completion scripts and the installers that fetch them, so the interesting parts are:

- The installers, `docs/install.sh` and `docs/install.ps1`, including what they write and where.
- The generated completion scripts under `docs/completions/`, in particular anything a shell would treat as code rather than as inert text.
- The generator under `src/`, which turns `quarto --help` output into those scripts.
- The workflows under `.github/workflows/`, which build and publish them.

The supported version is whatever is currently published at <https://m.canouil.dev/quarto-completions>.
There are no maintained older releases to backport to.

## What is already known

These are design limits rather than vulnerabilities, and reports of them will be closed as such:

- The published checksum in `manifest.json` is served from the same site as the scripts it describes, so it detects a truncated or corrupted download, not a compromised host.
  The trust boundary is the HTTPS connection to the site.
- The `dev` channel is generated from `quarto-dev/quarto-cli`'s `main`, an unreviewed third-party branch.
  Command names, flags, and values taken from its help output are escaped for each target shell before they are written, and that escaping is the control; a way past it is very much in scope.
- Installing by piping a script from the network into a shell is the documented method, and carries the properties that method always carries.
