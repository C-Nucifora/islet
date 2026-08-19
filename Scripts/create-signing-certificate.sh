#!/bin/bash
# Creates the local code-signing certificate Islet builds against.
#
# Why this exists: TCC keys every permission grant on an app's *designated requirement*. An
# ad-hoc signature ("CODE_SIGN_IDENTITY = -") produces a requirement that is a bare cdhash, and
# the cdhash changes every time the binary is rebuilt — so macOS treats each build as a brand-new
# app and silently drops Accessibility, Calendar, Reminders and the rest. You re-grant forever.
#
# Signing with one certificate makes the requirement
#     identifier "dev.cnucifora.Islet" and certificate root = H"<cert hash>"
# which is identical across rebuilds, so grants persist.
#
# Self-signed is enough — TCC only needs the requirement to be stable, not the certificate to be
# trusted by Apple. An Apple Developer ID works the same way and additionally allows notarisation.
#
# Run once per machine. Safe to re-run: it exits if the identity already exists.
#
# To undo:  security delete-certificate -c "Islet Dev"
set -euo pipefail

NAME="Islet Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists — nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = ext

[ dn ]
CN = Islet Dev
O  = Islet
C  = AU

[ ext ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# macOS Security.framework cannot read the PKCS#12 MAC that OpenSSL 3 writes by default, so the
# bundle is exported with the older SHA-1/3DES algorithms it does understand.
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/islet.p12" \
  -passout pass:islet -name "$NAME" \
  -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES 2>/dev/null

security import "$WORK/islet.p12" -k "$KEYCHAIN" -P islet \
  -T /usr/bin/codesign -T /usr/bin/security

echo
security find-identity -v -p codesigning | grep "\"$NAME\"" || {
  echo "Import succeeded but the identity is not valid for code signing." >&2
  exit 1
}
echo
echo "Done. Build normally — project.yml already sets CODE_SIGN_IDENTITY to \"$NAME\"."
echo "Grant Islet its permissions once more; from then on they survive rebuilds."
