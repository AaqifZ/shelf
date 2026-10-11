#!/bin/sh
# Create a self-signed code-signing certificate "shelf-local" in your login keychain. Run it once per Mac.
# Why: macOS ties the Accessibility and Screen Recording permissions to the app's signature.
# An ad-hoc signature changes on every build, so each rebuild asks for the permissions again.
# A fixed certificate keeps them. The certificate only signs shelf on this Mac; it is not trusted for anything else.
set -e
NAME=shelf-local
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "$NAME exists"
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cs.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$tmp/key" -out "$tmp/cert" -config "$tmp/cs.cnf" 2>/dev/null
# The keychain reads only the legacy PKCS#12 format. OpenSSL 3 needs -legacy for it; macOS's LibreSSL writes it by default.
LEGACY=""
openssl version | grep -q '^OpenSSL 3' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$tmp/key" -in "$tmp/cert" -name "$NAME" -out "$tmp/p12" -passout pass:shelf
security import "$tmp/p12" -k "$HOME/Library/Keychains/login.keychain-db" -P shelf -T /usr/bin/codesign
echo "$NAME created"
