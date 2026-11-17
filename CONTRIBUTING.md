# Contributing

Thanks for considering a contribution.

## Development setup

Requirements:

- macOS 13 or newer.
- Xcode Command Line Tools (full Xcode is not needed).
- For manual testing against a real node: Tailscale, signed in. Docker only when testing Docker discovery.

The app is built with plain `swiftc` from every `.swift` file under `Sources/TailscaleControl/` (Swift 5 language mode, macOS 13 deployment target). There is no Xcode project or package manifest.

```bash
make typecheck   # fast type-check
make build       # build and ad-hoc sign build/Tailscale Control.app
make test        # build, then run --self-test and --close-self-test
make verify      # test, plus Info.plist and code signature checks
make dmg         # verify, then create dist/Tailscale-Control-<version>.dmg
```

If `swiftc` fails because the Xcode license has not been accepted, run `export DEVELOPER_DIR=/Library/Developer/CommandLineTools` first (`scripts/build.sh` also does this automatically when the `swiftc` on your `PATH` does not run).

Code layout: `App/` (entry point, window, launch arguments), `Core/` (process runner, CLI wrapper, models, store, demo backend, self-tests) and `UI/` (SwiftUI views). Keep logic that can be tested without a window in `Core/` and add checks to `Core/SelfTest.swift`.

## Try it without touching a real node

Run the app in demo mode:

```bash
"build/Tailscale Control.app/Contents/MacOS/Tailscale Control" --demo
```

Demo mode uses fictional data and never starts a process. Use it for UI work and for screenshots (`--section=<name>`, `--show=add-route`, `--show=connect-options` open a specific screen). New commands the app can run should be handled in `Core/DemoBackend.swift`, so they work in demo mode too; anything it does not recognise is only logged as "(demo — not executed)".

## Safety rules for changes

This app controls a local network daemon. Please keep these properties intact:

- Never run user input through a shell. Build commands as argument arrays and start them with `CommandRunner`.
- Validate ports, hosts, schemes, mount paths and service names before building a command.
- Show the command before running anything that changes state, and ask for confirmation for destructive actions.
- Mask secrets (`--auth-key` and similar) in previews and logs.
- Read-only refreshes must stay read-only. Self-tests must not run `tailscale`.
- Process execution happens only through `CommandRunner` (called by `TailscaleCLI` and `DockerDiscovery`), so demo mode can switch it off in one place.
- No telemetry, analytics or network calls of the app's own.
- Do not use Tailscale's logo or brand marks. This is an unofficial app.

## Pull request checklist

- [ ] `make verify` passes with no compiler warnings.
- [ ] UI changes were launched and looked at, ideally in demo mode.
- [ ] New or changed behavior is covered by a self-test where it can be.
- [ ] `build/` and `dist/` are not committed.
- [ ] Documentation and `CHANGELOG.md` are updated for user-visible changes.
- [ ] No personal data: no real host names, tailnet names, e-mail addresses, IP addresses, tokens, or home-directory paths in code, docs, tests or screenshots. Use placeholders such as `host.example.ts.net`, `user@example.com`, `100.64.0.x` and `/Users/me/...`.
