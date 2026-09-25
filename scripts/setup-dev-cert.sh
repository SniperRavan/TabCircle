#!/bin/bash
# Generate a local self-signed code signing certificate for TabCircle development on macOS.
# Binds TCC accessibility permission to certificate + bundle identifier rather than cdhash.
set -euo pipefail

CERT_NAME="TabCircle Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ Certificate already exists: $CERT_NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no

[dn]
CN = TabCircle Dev

[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

echo "▸ Generating self-signed certificate..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

echo "▸ Importing to keychain..."
security import "$WORK/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
security import "$WORK/key.pem"  -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null

security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    echo "  (Could not auto-authorize private key; click 'Always Allow' on first prompt)"

echo
security find-identity -p codesigning | grep "$CERT_NAME" || true
echo "✅ Complete. build-app.sh will now use this certificate for signing."
