# Security Policy

## Supported versions

Security fixes are made for the latest release and the current `main` branch.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting for this repository, if it is enabled. If it is not, open a minimal issue asking for a private contact, without exploit details.

## Security model

Tailscale Control is a local macOS app. It runs the `tailscale` command-line tool (and `docker`, for container discovery) as the current user, and it does not listen on any network port.

Boundaries to be aware of:

- **No shell.** Commands are built as argument arrays and started directly. Values the user types are validated first and never interpreted by a shell. The custom-command box tokenizes quotes only; it does not expand variables, globs, pipes or substitutions.
- **The app can change your Tailscale configuration** when you press an apply, reset, connect or similar button. It shows the command first and asks for confirmation for destructive actions. It does not need administrator rights.
- **Read-only refreshes** only run read-only `tailscale` commands.
- **Secrets** passed as `--auth-key`, `--client-secret` or `--id-token` are masked in previews and in the Activity Log, but they are still visible to other local processes in the process list while a command runs. Prefer `file:` references where Tailscale supports them.
- **Releases are ad-hoc signed**, not notarized. Verify downloads against the build you expect, or build from source.
- **No telemetry** and no network requests of the app's own. See [PRIVACY.md](PRIVACY.md).
- **Demo mode** (`--demo`) disables process execution entirely.
