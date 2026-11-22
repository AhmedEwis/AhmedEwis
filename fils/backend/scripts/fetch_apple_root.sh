#!/usr/bin/env bash
# Downloads Apple Root CA - G3 (used to verify StoreKit 2 / App Store Server Notification JWS).
# Verify the printed SHA-256 fingerprint against https://www.apple.com/certificateauthority/ before deploying.
set -euo pipefail
dest="$(dirname "$0")/../fils_api/certs/AppleRootCA-G3.cer"
curl -fsSL -o "$dest" https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
openssl x509 -inform DER -in "$dest" -noout -subject -fingerprint -sha256
