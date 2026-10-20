# Signing and notarizing releases

Without this, a downloaded copy of AI Keeper triggers a Gatekeeper warning and users must right-click the app and choose
Open. (Homebrew installs avoid it because the cask clears the quarantine flag.) The fix is two things Apple requires:
a **Developer ID signature** and **notarization**. Both need a paid Apple Developer Program membership (US$99 a year).
Nothing in code can replace that, but once the credentials exist the release workflow does everything else.

## One-time setup

1. **Join the Apple Developer Program** at https://developer.apple.com/programs/. Approval can take a day or two.

2. **Create a "Developer ID Application" certificate.** In Xcode: Settings → Accounts → select your team →
   Manage Certificates → **+** → *Developer ID Application*. (Only the Account Holder or an Admin can create this type.)

3. **Export it** from Keychain Access: My Certificates → *Developer ID Application: Your Name (TEAMID)* →
   right-click → Export → save as `.p12` with a password you will remember.

4. **Create notarization credentials.** Either:
   - **API key (recommended):** App Store Connect → Users and Access → Integrations → App Store Connect API →
     Team Keys → generate a key with the *Developer* role. Download the `.p8` file (Apple shows it only once) and note
     the **Key ID** and **Issuer ID**.
   - **Apple ID:** create an app-specific password at https://account.apple.com (Sign-In and Security →
     App-Specific Passwords) and note your 10-character **Team ID**.

5. **Store them as GitHub secrets** by running, in a terminal where `gh` is signed in as the repository owner:

   ```bash
   ./scripts/setup-signing.sh
   ```

   It checks the certificate and password first, uploads six secrets, and prints only their names.

6. **Cut a release.**

   ```bash
   git tag v0.1.1 && git push origin v0.1.1
   ```

   The run summary on GitHub should say **Signed and notarized**.

## Checking the result yourself

Download the zip from the release, unzip it, and run:

```bash
spctl --assess --type execute -vv "AI Keeper.app"
# AI Keeper.app: accepted
# source=Notarized Developer ID
xcrun stapler validate "AI Keeper.app"
```

When that passes, update the install notes in `README.md` and `site/index.html` to drop the "not notarized yet" wording.

## Signing locally

```bash
VERSION=0.1.1 \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARIZE=1 APPLE_API_KEY_P8="$(base64 < AuthKey_XXXX.p8)" APPLE_API_KEY_ID=XXXX APPLE_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
./scripts/package.sh
```

## How the workflow behaves

| Secrets present | Result |
|---|---|
| None | Ad-hoc signed build, a warning in the run, Gatekeeper warns users |
| All of them | Signed with Developer ID, notarized, stapled, verified with `spctl` and `stapler` |
| Some of them | The release **fails** with a message listing what is missing, so a half-signed build is never published |

If Apple rejects the build, the workflow prints Apple's rejection log and stops. The usual causes are unsigned nested code
or a missing hardened runtime or secure timestamp; the packaging script already enables both, and AI Keeper is tested
to run correctly under the hardened runtime.

## Security

The certificate is imported into a temporary keychain on the runner and discarded with it. Secrets are only
readable by the workflow. Never commit a `.p12` or `.p8` file.
