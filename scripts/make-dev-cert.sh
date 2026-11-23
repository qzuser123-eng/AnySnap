#!/bin/bash
# Optional, run once: create a self-signed "AnySnap Dev" code-signing certificate in the
# login keychain. Signing every build with the same certificate means macOS keeps the
# Accessibility / Screen Recording permissions after you rebuild.
# macOS will ask for your login password to trust the certificate.
set -euo pipefail

NAME="AnySnap Dev"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✅ \"$NAME\" already exists"; exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf"
# -legacy is needed for OpenSSL 3 so that `security import` can read the file
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/cert.p12" -passout pass:anysnap 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
       -out "$TMP/cert.p12" -passout pass:anysnap

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P anysnap -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "✅ Created \"$NAME\". scripts/build-app.sh will use it automatically."
