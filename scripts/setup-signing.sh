#!/bin/bash
#
# One-time setup: create a self-signed code-signing identity for SoundFlow.
#
# Why this exists
# ---------------
# `codesign --sign -` (ad-hoc) produces a Designated Requirement based on the
# binary's cdhash. That hash changes on every rebuild, so macOS TCC silently
# revokes the "System Audio Recording" grant after each build with no new
# prompt. A self-signed certificate gives a stable DR of the form
#
#     identifier "com.soundflow.app" and certificate leaf[subject.CN] = "SoundFlow Dev"
#
# which survives rebuilds. Local development only -- not distributable.
#
# Idempotent: safe to re-run.

set -euo pipefail

CN="SoundFlow Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# Security.framework fails MAC verification on a zero-length PKCS#12 password,
# so the bundle needs a real (if pointless) passphrase. It never leaves this file.
P12_PASS="soundflow-local"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

manual_fallback() {
    cat <<EOF

────────────────────────────────────────────────────────────────────
Automatic setup failed. Create the certificate by hand instead:

  1. Open Keychain Access
  2. Menu: Keychain Access -> Certificate Assistant ->
           Create a Certificate...
  3. Name:              $CN
     Identity Type:     Self Signed Root
     Certificate Type:  Code Signing
  4. Click Create, then Done.
  5. Re-run ./build.sh
────────────────────────────────────────────────────────────────────
EOF
    exit 1
}

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$CN"; then
    echo "✓ Code-signing identity \"$CN\" already present. Nothing to do."
    exit 0
fi

echo "=== Generating self-signed code-signing certificate: $CN ==="

# extendedKeyUsage=codeSigning is what makes `codesign` accept this identity.
cat > "$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = $CN

[ ext ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK_DIR/key.pem" \
    -out    "$WORK_DIR/cert.pem" \
    -config "$WORK_DIR/openssl.cnf" 2>/dev/null || manual_fallback

# Bundle key + cert into a PKCS#12 so `security import` installs both halves.
# OpenSSL 3 defaults to AES/SHA-256 PBE, which Security.framework rejects on
# import -- the legacy SHA1/3DES algorithms are required here.
openssl pkcs12 -export \
    -inkey "$WORK_DIR/key.pem" \
    -in    "$WORK_DIR/cert.pem" \
    -out   "$WORK_DIR/identity.p12" \
    -name  "$CN" \
    -passout "pass:$P12_PASS" \
    -keypbe  PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg  sha1 2>/dev/null || manual_fallback

echo "=== Importing into login keychain ==="
# -T codesign pre-authorizes codesign to use the private key without prompting.
security import "$WORK_DIR/identity.p12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null || manual_fallback

# Suppress the "codesign wants to access key" dialog on every build.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo "=== Trusting for code signing ==="
# Until the cert is trusted for codeSign, find-identity will not list it.
# A user-keychain trust setting needs no sudo.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem" 2>/dev/null \
    || echo "  (warning: could not set trust automatically)"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "$CN"; then
    echo
    echo "✓ Identity \"$CN\" is ready."
    echo "  Next: ./build.sh"
else
    manual_fallback
fi
