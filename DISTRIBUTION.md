# Distributing Meeting Coach

How a shared build reaches other Macs: a **signed + notarized `.dmg`** attached to
a **GitHub Release**, built automatically by CI when you push a version tag.

- The app **bundles the Ollama runtime (~80MB)** so users don't install Ollama.
- The app does **not** bundle a model. On first launch the user clicks
  **"Download model"** and Ollama pulls it to `~/Library/Application Support/MeetingCoach/ollama`.
  (This is the one moment the app needs WiFi; everything after is offline.)

---

## One-time setup

### 1. Apple Developer account + Developer ID cert
Notarization requires the **paid Apple Developer Program** ($99/yr). Then, in
Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates, create a
**Developer ID Application** certificate. Export it as a `.p12` (with a password).

Find your identity string and Team ID:
```bash
security find-identity -v -p codesigning   # → "Developer ID Application: Noah Kagan (TEAMID1234)"
```

### 2. App-specific password for notarization
At <https://appleid.apple.com> ▸ Sign-In & Security ▸ App-Specific Passwords,
create one for "notarytool".

### 3. GitHub repo secrets
Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret:

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | the `.p12` export password |
| `MACOS_KEYCHAIN_PASSWORD` | any throwaway string (temp CI keychain) |
| `MACOS_DEVELOPER_ID_APP` | `Developer ID Application: Noah Kagan (TEAMID1234)` |
| `MACOS_TEAM_ID` | your 10-char Team ID |
| `MACOS_NOTARY_APPLE_ID` | your Apple ID email |
| `MACOS_NOTARY_PASSWORD` | the app-specific password from step 2 |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle update-signing key (already set; local copy: `~/.config/meeting-coach/sparkle_ed_private_key`, also in the login keychain) |
| `RELEASES_TOKEN` | a fine-grained PAT with **Contents: read/write** on `noahdevkagan/meeting-coach-releases` — lets CI publish the DMG + appcast there |

---

## Cut a release
```bash
git tag v0.1.0
git push origin v0.1.0
```
CI (`.github/workflows/release.yml`) builds, signs, notarizes, and uploads
`MeetingCoach-0.1.0.dmg` to the GitHub Release. Users download it, drag to
Applications, and double-click — no Gatekeeper warning.

You can also run it manually from the Actions tab (workflow_dispatch); it asks
for a version and creates the `v<version>` tag + Release itself.

The pipeline notarizes **twice, in order**: app → staple the `.app` → build the
DMG → notarize + staple the DMG. Stapling the app itself matters because users
drag it out of the DMG — an offline Mac can't fetch a ticket for an unstapled app.
It also regenerates the Xcode project from `project.yml` (source of truth) and
asserts the Ollama runtime is present in the built bundle before signing.

---

## Build a release locally (optional)
Requires `brew install xcodegen`.
```bash
export DEVELOPER_ID_APP="Developer ID Application: Noah Kagan (TEAMID1234)"
export TEAM_ID="TEAMID1234"
export APPLE_ID="you@example.com"
export APPLE_PASSWORD="abcd-efgh-ijkl-mnop"   # app-specific password
export VERSION="0.1.0"
./scripts/package-release.sh
# → dist/MeetingCoach-0.1.0.dmg
```

---

## The Ollama runtime bundle
`scripts/vendor-ollama.sh` populates `MeetingCoach/MeetingCoach/Resources/ollama/`
(gitignored — never committed). Two sources:

- **Pinned download (default):** grabs the official Ollama macOS release
  (`OLLAMA_VERSION`, default `v0.5.7`).
- **Known-good copy:** point it at binaries that already work —
  ```bash
  OLLAMA_SRC=/Applications/Ollama.app ./scripts/vendor-ollama.sh
  ```
  Use this if the pinned download's internal layout doesn't match what
  `OllamaManager.swift` expects (it looks for `Resources/ollama/ollama` plus the
  runner dylibs alongside it).

> ⚠️ **Verify once:** the exact runner/dylib layout is Ollama-version-specific.
> After vendoring, confirm the embedded server actually starts before shipping:
> ```bash
> cd MeetingCoach/MeetingCoach/Resources/ollama
> OLLAMA_HOST=127.0.0.1:11500 DYLD_LIBRARY_PATH="$PWD" ./ollama serve
> ```
> If that serves, the bundled app will too. If not, use the `OLLAMA_SRC` route
> with binaries from a working Ollama install.

---

## Auto-updates (Sparkle)

The app embeds [Sparkle](https://sparkle-project.org): installed copies check
`SUFeedURL` (the `appcast.xml` in the public
[`meeting-coach-releases`](https://github.com/noahdevkagan/meeting-coach-releases)
repo) and show the standard "a new version is available" panel with a
Download & Install button. No user action needed beyond clicking Install.

How a release becomes an update prompt:
1. `package-release.sh` EdDSA-signs the DMG (`SPARKLE_ED_PRIVATE_KEY`) and
   writes `dist/appcast.xml`; the app verifies with the baked-in `SUPublicEDKey`.
2. CI uploads the DMG to the public repo's Release and commits `appcast.xml`
   to its `main`.
3. Installed apps poll the feed (daily by default) and prompt.

Notes:
- **`CFBundleVersion` must advance every release** — Sparkle compares it, not
  the marketing version. The pipeline stamps both from the tag, so just tag.
- The code repo stays private; only the DMG + appcast are public.
- Losing the Sparkle private key means shipped apps reject your future
  updates — it's in the login keychain, `~/.config/meeting-coach/`, and the
  repo secret. Don't rotate it casually.

---

## Homebrew Cask (optional, nicest one-liner)
Once you have notarized releases, a tap makes install a single command:
```bash
brew install --cask noahdevkagan/tap/meeting-coach
```
Create a `homebrew-tap` repo with a cask pointing at the Release `.dmg` + its
SHA256. Ask and I'll scaffold it.
