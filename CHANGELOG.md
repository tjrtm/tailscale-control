# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.0.0]

First stable release. The app grew from a single-window serve helper into a full control app for a local Tailscale node.

### Added

- Sidebar app with Overview, Serve & Funnel, Services, Devices, Exit Nodes, Preferences, Tools and Activity Log.
- Overview: connection state, identity, key expiry, connect and disconnect, "Connect with options", re-authenticate, log out, sign-in link handling and account switching.
- Serve & Funnel: editor for HTTPS, HTTP, TCP and TLS-terminated TCP routes with mount paths, proxy, file and text targets, per-route Funnel, quick routes, Docker discovery and bulk reset. Commands are previewed before they run.
- Services: Tailscale Services hosted by this node, drain, advertise, clear, and configuration export and import.
- Devices: sortable and searchable table with an inspector (addresses, connection path, routes, capabilities), ping, whois, Taildrop send and SSH helpers.
- Exit Nodes: choose, suggest and clear exit nodes, LAN access, and advertising this device as an exit node.
- Preferences: the `tailscale set` options as switches and fields, applied together, with confirmation for risky changes.
- Tools: forms for netcheck, ping, DNS, IP, status, whois, certificates, Taildrop receive, version and update dry run, metrics, Tailnet Lock, system policy, licenses, bug report and the web interface, plus a custom-command box with live streaming output and confirmation for commands that are not read-only.
- Activity Log of every command run by the app, with filtering and export. Secrets are masked.
- Menu bar item with connection controls, exit node picker and quick navigation. It can be turned off in Settings.
- Demo mode (`--demo`): built-in fictional data, no process is ever started, and mutating actions are simulated and logged as "(demo — not executed)". A "Demo" badge is shown in the toolbar.
- Launch arguments `--section=<name>`, `--show=add-route` and `--show=connect-options` for documentation screenshots.
- App icon, drawn at build time by `scripts/make-icon.swift`.
- Self-tests (`--self-test`) for command builders, parsers and the demo backend.
- `CHANGELOG.md` and a `VERSION` file as the single source of the app version.

### Changed

- Rewritten as a multi-file SwiftUI app (`App/`, `Core/`, `UI/`), still built with plain `swiftc`.
- A login command that times out after printing its sign-in URL is no longer reported as an error.
- Navigating to a section from the menu bar while the window is closed now works without a delay.
- Custom commands that may change state mark the app busy while they run.
- The Devices table fits the default window width: connection details are merged into the status column, and owner and tags moved into the inspector.
- Port numbers are shown without a thousands separator (for example "Port 8050").
- The route editor sheet is more compact so that it fits the default window.
- Documentation rewritten for 1.0. The release workflow derives the version from the tag and checks it against `VERSION`.

### Security and privacy

- Commands are started from argument arrays without a shell; inputs are validated before a command is built.
- No telemetry, and no network requests of the app's own.
