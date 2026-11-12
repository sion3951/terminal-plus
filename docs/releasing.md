# Releases

`terminal+-VERSION-x86_64.AppImage` (Linux x86_64) and `terminal+-VERSION-arm64.dmg`
(macOS, Apple silicon) are published from `vX.Y.Z` tags. GitHub Actions builds
the AppImage on Ubuntu 22.04 with pinned Odin, GLFW and AppImage tools, builds
the disk image on a `macos-14` runner (`.github/workflows/macos.yml`), bundles
native libraries, and signs update metadata covering both before publishing.
macOS is experimental: if its build fails, the release still publishes the
AppImage alone, and the release notes flag the disk image as experimental.

One-time setup: save `.update-signing/private.pem` securely and set the repository
Actions secret without printing the key:

```sh
gh secret set TERMINAL_PLUS_UPDATE_PRIVATE_KEY < .update-signing/private.pem
```

The private key stays out of Git. Its matching public key is embedded from
`assets/update-public-key.hex`; keep the private key for future releases.

To publish:

```sh
git tag v0.1.1
git push origin v0.1.1
```

Prerelease tags do not enter the stable update channel. A failed draft can be
resumed with the workflow's manual tag input; published releases are immutable.

For a local build, install the dependencies in [building.md](building.md), then run
`make -j VERSION=0.1.1 appimage`. Sign its package with
`scripts/update-manifest.py --tag v0.1.1 --packages build/packages --private-key .update-signing/private.pem`.

Users run the AppImage directly or pass `--install` once for the applications
menu and `terminal+` command. Installation is per user; updates replace the same
AppImage atomically and keep the command link. GPU drivers, host CA certificates,
POSIX sh/standard Linux utilities, OpenSSH and FFmpeg (for image/video viewing) remain host dependencies.
Bundled library and font licenses are included inside the AppImage.

## macOS signing

Without extra secrets the app is ad-hoc signed: it runs, but Gatekeeper asks
users to approve it once in System Settings → Privacy & Security. To ship a
notarized build, add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64 of a "Developer ID Application" `.p12` export |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` password |
| `MACOS_SIGN_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Notarization account, team and app-specific password |

To test a macOS build without tagging, run **Actions → macOS app → Run
workflow** and download the `macos-dmg` artifact. On a Mac, `make -j dmg`
produces the same image locally; `CODESIGN_IDENTITY` and `NOTARY_PROFILE`
enable Developer ID signing and notarization there.
