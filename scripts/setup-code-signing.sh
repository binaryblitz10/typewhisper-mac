#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="TypeWhisper Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "=== TypeWhisper Code Signing Setup ==="
echo ""

# Check if identity already exists (cert + private key paired)
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Signing identity '$CERT_NAME' already exists and is valid."
  echo "Nothing to do."
  exit 0
fi

echo "Generating self-signed code signing certificate..."
echo ""

CERT_DIR="$HOME/.typewhisper"
mkdir -p "$CERT_DIR"

# Generate cert + key
openssl req -x509 -newkey rsa:2048 \
  -keyout "$CERT_DIR/key.pem" \
  -out "$CERT_DIR/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=$CERT_NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature"

# Package as PKCS12 so keychain pairs cert + key as a single identity
openssl pkcs12 -export \
  -inkey "$CERT_DIR/key.pem" \
  -in "$CERT_DIR/cert.pem" \
  -out "$CERT_DIR/identity.p12" \
  -passout pass:typewhisper \
  -name "$CERT_NAME"

# Import the PKCS12 (cert + key as a paired identity)
security import "$CERT_DIR/identity.p12" \
  -k "$KEYCHAIN" \
  -P typewhisper \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/xcodebuild

# Allow codesign to access the private key without prompting
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

# Clean up sensitive files
rm -f "$CERT_DIR/key.pem" "$CERT_DIR/identity.p12"

echo ""
echo "Signing identity '$CERT_NAME' installed and ready."
echo "Certificate (public): $CERT_DIR/cert.pem"
echo ""
echo "You can now build with: scripts/build-release-local.sh"
