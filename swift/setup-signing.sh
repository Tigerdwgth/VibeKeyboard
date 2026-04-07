#!/bin/bash
# setup-signing.sh — Create a self-signed code signing certificate (one-time)
#
# With a proper certificate (not ad-hoc), macOS TCC matches by signing identity
# instead of binary hash. This means accessibility permissions survive app rebuilds.
#
# Usage: bash setup-signing.sh

set -euo pipefail

CERT_NAME="VibeKeyboard Developer"

# Check if already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists."
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "Creating self-signed code signing certificate: $CERT_NAME"
echo ""

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Use certtool (macOS built-in) to create a self-signed certificate
# This avoids openssl compatibility issues with LibreSSL
cat > "$TMPDIR/cert.cfg" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>certType</key>
    <string>custom</string>
    <key>extendedKeyUsage</key>
    <array>
        <string>codeSigning</string>
    </array>
    <key>keyUsage</key>
    <array>
        <string>digitalSignature</string>
    </array>
</dict>
</plist>
EOF

# Create the self-signed certificate using the security framework
# This creates both the key and cert in the login keychain directly
cat > "$TMPDIR/create_cert.py" << 'PYEOF'
import subprocess, sys

# Use 'security create-keychain' approach won't work easily.
# Instead, use openssl with DER format which LibreSSL handles better.

import tempfile, os

tmpdir = sys.argv[1]
cert_name = "VibeKeyboard Developer"

# Generate key
subprocess.run([
    "openssl", "req", "-x509", "-newkey", "rsa:2048",
    "-keyout", f"{tmpdir}/key.pem",
    "-out", f"{tmpdir}/cert.pem",
    "-days", "3650", "-nodes",
    "-subj", f"/CN={cert_name}",
], check=True, capture_output=True)

# Convert to DER for import
subprocess.run([
    "openssl", "x509", "-in", f"{tmpdir}/cert.pem",
    "-out", f"{tmpdir}/cert.der", "-outform", "DER"
], check=True, capture_output=True)

subprocess.run([
    "openssl", "rsa", "-in", f"{tmpdir}/key.pem",
    "-out", f"{tmpdir}/key.der", "-outform", "DER"
], check=True, capture_output=True)

# Import private key
result = subprocess.run([
    "security", "import", f"{tmpdir}/key.der",
    "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db"),
    "-t", "priv",
    "-T", "/usr/bin/codesign",
], capture_output=True, text=True)
if result.returncode != 0:
    print(f"Key import: {result.stderr.strip()}")

# Import certificate
result = subprocess.run([
    "security", "import", f"{tmpdir}/cert.der",
    "-k", os.path.expanduser("~/Library/Keychains/login.keychain-db"),
    "-t", "cert",
    "-T", "/usr/bin/codesign",
], capture_output=True, text=True)
if result.returncode != 0:
    print(f"Cert import: {result.stderr.strip()}")
    sys.exit(1)

print(f"Certificate '{cert_name}' imported successfully.")
PYEOF

python3 "$TMPDIR/create_cert.py" "$TMPDIR"

# Trust the certificate for code signing
echo "Trusting certificate for code signing (may need password)..."
security add-trusted-cert -p codeSign \
    -k ~/Library/Keychains/login.keychain-db \
    "$TMPDIR/cert.pem" 2>/dev/null || {
    echo ""
    echo "NOTE: Auto-trust failed. Please manually trust the certificate:"
    echo "  1. Open Keychain Access"
    echo "  2. Find '$CERT_NAME' under Certificates"
    echo "  3. Double-click > Trust > Code Signing > Always Trust"
}

# Allow codesign to access without prompt
security set-key-partition-list -S apple-tool:,apple: -s \
    -k "" ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo ""
echo "Verifying..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "=== Success ==="
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo ""
    echo "Now run: bash package.sh"
    echo "Accessibility permissions will persist across rebuilds."
else
    echo "=== Certificate created but not yet trusted for codesigning ==="
    echo "Please open Keychain Access and trust '$CERT_NAME' for Code Signing."
fi
