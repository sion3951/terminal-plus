# Releases

`terminal+-VERSION-x86_64.AppImage` Linux x86_64 packages are published from `vX.Y.Z` tags. GitHub Actions builds
on Ubuntu 22.04 with pinned Odin, GLFW and AppImage tools, bundles native
libraries, and signs update metadata before publishing.

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

For a local build, install the dependencies in [BUILD.md](BUILD.md), then run
`make -j VERSION=0.1.1 appimage`. Sign its package with
`scripts/update-manifest.py --tag v0.1.1 --packages build/packages --private-key .update-signing/private.pem`.

Users run the AppImage directly or pass `--install` once for the applications
menu and `terminal+` command. Installation is per user; updates replace the same
AppImage atomically and keep the command link. GPU drivers, host CA certificates,
POSIX sh/standard Linux utilities, OpenSSH and FFmpeg (for image/video viewing) remain host dependencies.
Bundled library and font licenses are included inside the AppImage.
