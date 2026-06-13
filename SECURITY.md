# Security Policy

## Supported versions

Security fixes are accepted for the latest released version and the current `main` branch.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting feature if it is enabled for the repository. If it is not enabled, open a minimal issue asking for a private disclosure contact without posting exploit details.

## Security model

Tailscale Control is a local macOS utility. It shells out to local CLIs using explicit argument arrays and does not run a network service.

Important boundaries:

- The app can change local `tailscale serve` configuration when the user clicks an apply/reset control.
- Docker discovery reads local Docker metadata through the `docker` CLI.
- The app should not collect telemetry or send project data to third-party services.
- User-provided command parts must remain validated and must not be passed through shell interpolation.
