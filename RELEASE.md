# Release Guide

Releases are macOS DMG files attached to GitHub Releases. The version lives in the `VERSION` file at the repository root; `scripts/build.sh` and `scripts/package-dmg.sh` read it, and the CI workflow checks that a release tag matches it.

## Maintainer steps

1. Update `VERSION` (for example `1.0.1`) and add an entry to `CHANGELOG.md`.
2. Make sure the tree is clean and verification passes:

   ```bash
   make verify
   ```

3. Optionally build the DMG locally and try it:

   ```bash
   make dmg      # dist/Tailscale-Control-<version>.dmg
   ```

4. Commit, then tag with a `v` prefix that matches `VERSION` and push the tag:

   ```bash
   git tag v1.0.1
   git push origin v1.0.1
   ```

5. The workflow in `.github/workflows/release.yml` builds on a macOS runner, runs the self-tests, verifies the bundle, packages the DMG, uploads the app and DMG as artifacts and attaches the DMG to the GitHub Release. It fails if the tag does not match `VERSION`.

The same workflow also runs on pull requests and manual dispatches; those builds use the version from `VERSION` and do not publish a release.

## Signing

Release builds are signed ad hoc (`codesign --sign -`). They are not signed with a Developer ID certificate and are not notarized, so macOS Gatekeeper warns on first launch. The README explains how users can open the app anyway. For wider distribution, configure Developer ID signing and notarization in the workflow.

## Notes for users

Download `Tailscale-Control-<version>.dmg` from the release, open it and drag the app to Applications. See the README for the Gatekeeper steps.
