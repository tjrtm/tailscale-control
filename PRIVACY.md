# Privacy

Tailscale Control is a local desktop utility.

- No telemetry.
- No analytics.
- No remote API calls made by the app itself.
- No bundled update checker.
- Docker discovery reads local Docker metadata through the `docker` CLI.
- Tailscale actions are performed through the local `tailscale` CLI.

The app displays command output locally so users can see what happened. It does not transmit that output anywhere.
