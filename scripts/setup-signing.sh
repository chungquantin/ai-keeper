#!/bin/bash
# Stores your Developer ID certificate and notarization credentials as GitHub secrets for the release workflow.
# Run it yourself in a terminal. Nothing secret is printed, logged or kept on disk.
# See docs/SIGNING.md for how to get each item.
set -euo pipefail
REPO="${REPO:-chungquantin/ai-keeper}"

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh"; exit 1; }
who="$(gh api user --jq .login)"
if [ "$who" != "${REPO%%/*}" ]; then
  echo "gh is signed in as '$who', but $REPO belongs to '${REPO%%/*}'."
  echo "Run 'gh auth login' (or 'gh auth switch') as the repository owner, then try again."
  exit 1
fi

echo "Developer ID certificates found in your keychain:"
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "  (none: create one first, see docs/SIGNING.md step 2)"
echo
read -r -p "Signing identity, exactly as shown above (Developer ID Application: Name (TEAMID)): " IDENT
read -r -p "Path to the exported .p12 certificate: " P12
read -r -s -p "Password you chose when exporting the .p12: " P12PW; echo

# Check the certificate and password before uploading anything.
P12PW="$P12PW" openssl pkcs12 -in "$P12" -passin env:P12PW -noout 2>/dev/null \
  || { echo "That .p12 or password is not valid. Nothing was uploaded."; exit 1; }

echo
echo "How will notarization sign in?"
echo "  1) App Store Connect API key (recommended)"
echo "  2) Apple ID with an app-specific password"
read -r -p "Choice [1/2]: " CHOICE

if [ "$CHOICE" = "2" ]; then
  read -r -p "Apple ID email: " AID
  read -r -p "Team ID (10 characters): " TEAM
  read -r -s -p "App-specific password: " APW; echo
else
  read -r -p "Path to the AuthKey_XXXX.p8 file: " P8
  read -r -p "Key ID: " KEYID
  read -r -p "Issuer ID: " ISSUER
  [ -f "$P8" ] || { echo "No file at $P8. Nothing was uploaded."; exit 1; }
fi

echo
echo "Uploading to $REPO..."
base64 < "$P12" | gh secret set MACOS_CERT_P12 -R "$REPO"
printf '%s' "$P12PW" | gh secret set MACOS_CERT_PASSWORD -R "$REPO"
printf '%s' "$IDENT" | gh secret set MACOS_SIGN_IDENTITY -R "$REPO"
if [ "$CHOICE" = "2" ]; then
  printf '%s' "$AID" | gh secret set APPLE_ID -R "$REPO"
  printf '%s' "$TEAM" | gh secret set APPLE_TEAM_ID -R "$REPO"
  printf '%s' "$APW" | gh secret set APPLE_APP_PASSWORD -R "$REPO"
else
  base64 < "$P8" | gh secret set APPLE_API_KEY_P8 -R "$REPO"
  printf '%s' "$KEYID" | gh secret set APPLE_API_KEY_ID -R "$REPO"
  printf '%s' "$ISSUER" | gh secret set APPLE_API_ISSUER -R "$REPO"
fi

echo
echo "Done. Secrets now set on $REPO:"
gh secret list -R "$REPO" | awk '{print "  " $1}'
echo
echo "Next: publish a release to try it, for example:  git tag v0.1.1 && git push origin v0.1.1"
