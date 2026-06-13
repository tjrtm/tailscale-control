# Release Guide

This project ships macOS builds as DMG files attached to GitHub Releases.

## Maintainer release steps

1. Make sure the tree is clean and verification passes:

   ```bash
   make verify
   ```

2. Create a local DMG if you want to inspect it before tagging:

   ```bash
   make dmg
   ```

3. Push a version tag:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

4. GitHub Actions will:
   - build `Tailscale Control.app`
   - run self-tests
   - create `Tailscale-Control-v0.1.0.dmg`
   - upload artifacts
   - attach the DMG to the GitHub Release

## User download instructions

Users should download the latest DMG from GitHub Releases, open it, drag the app to Applications, and launch it.

Because release builds are ad-hoc signed unless maintainers configure a Developer ID certificate, macOS Gatekeeper may show a warning on first launch. For public distribution, maintainers should configure notarized Developer ID signing in CI.
