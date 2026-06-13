# Contributing

Thanks for considering a contribution.

## Development setup

Requirements:

- macOS 13 or newer.
- Xcode Command Line Tools.
- Tailscale CLI for manual runtime testing.
- Docker CLI only when testing Docker target discovery.

Build and verify:

```bash
make verify
```

Create a DMG:

```bash
make dmg
```

## Safety rules for changes

This app controls local CLI tools. Please keep these properties intact:

- Do not execute user input through a shell string.
- Build commands as explicit argument arrays.
- Validate ports, hosts, schemes, and serve modes before command execution.
- Keep status/self-test paths non-mutating.
- Do not add telemetry, analytics, or network calls unrelated to the user's local Tailscale/Docker commands.

## Pull request checklist

- [ ] `make verify` passes.
- [ ] Any UI change was manually launched on macOS.
- [ ] No generated files from `build/` or `dist/` are committed.
- [ ] Documentation is updated for behavior changes.
- [ ] No personal paths, hostnames, tokens, or private project names are included.
