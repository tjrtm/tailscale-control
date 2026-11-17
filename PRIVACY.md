# Privacy

Tailscale Control is a local desktop app.

- No telemetry and no analytics.
- No account, no sign-in and no server operated by this project.
- The app makes no network requests of its own and has no update checker.
- Everything the app shows comes from commands run on your Mac: the `tailscale` command-line tool and, for container discovery, `docker`.
- Command output is shown in the app and kept in memory for the Activity Log of the current session. It is not written to disk unless you export it, and it is never transmitted.
- Settings (menu bar icon, custom `tailscale` path) are stored in the app's standard macOS preferences.

Some features cause Tailscale itself to contact Tailscale services or other parties, and only when you invoke them:

- **Bug Report** runs `tailscale bugreport`, which uploads diagnostic logs to Tailscale and prints a reference you can share.
- **Funnel** exposes a route to the public internet through Tailscale's relays when you turn it on for that route.
- **Certificates** (`tailscale cert`) request a certificate for your MagicDNS name, which involves a certificate authority.
- **Version & Updates** can run `tailscale version --upstream`, which asks Tailscale for the latest published release. `tailscale update --dry-run` only prints what an update would do.
- Ordinary Tailscale activity (connecting, ping, netcheck, Taildrop) is the Tailscale client's own traffic, not the app's.

Demo mode (`--demo`) uses built-in fictional data and starts no processes at all.
