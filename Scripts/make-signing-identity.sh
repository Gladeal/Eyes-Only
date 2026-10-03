#!/bin/bash
# Create the stable local code-signing identity used by build.sh
# ("Eyes Only Local Signing", a self-signed certificate in the login keychain). Run once.
#
# A stable identity matters: macOS ties Screen Recording approval to the app's
# code signature, so re-signing with the SAME identity keeps the permission
# across rebuilds. An ad-hoc (-) signature changes every build and forces you to
# re-approve each time.
set -euo pipefail

NAME="Eyes Only Local Signing"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Self-signed code-signing certificate.
cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/cert.conf"

# -legacy: emit the old PKCS12 MAC/PBE that macOS 'security import' can verify
# (OpenSSL 3's default MAC fails to import on macOS).
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:eyesonly

security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P eyesonly -T /usr/bin/codesign -A

# Let codesign use the key without a GUI prompt each build.
security set-key-partition-list -S apple-tool:,apple: -s \
  -k "" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1 || true

echo "Created identity '$NAME'. You may be asked to trust it for code signing."
