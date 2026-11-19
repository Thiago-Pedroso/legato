#!/bin/bash
# Creates a self-signed "Legato Dev" identity in its own keychain, once.
#
# macOS remembers the Microphone and Accessibility permissions by signature. Without a stable
# identity every rebuild looks like a new app and the permissions have to be granted again.
# Nothing here touches your login keychain. To undo: security delete-keychain legato-dev.keychain-db
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/legato-dev.keychain-db"
PASSWORD=legato
if security find-identity -p codesigning | grep -q '"Legato Dev"'; then
  echo "Legato Dev identity already exists."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Legato Dev
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "Legato Dev" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

[ -f "$KEYCHAIN" ] || security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
# Add the new keychain to the search list, keeping the ones already there.
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
echo "Created the Legato Dev signing identity."
