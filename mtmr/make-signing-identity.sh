#!/bin/bash
# One-time local signing setup. Preview with --dry-run; see docs/runbook-build-mtmr.md.
# macOS may ask "codesign wants to use key": choose Always Allow.
# No trust settings are changed.
set -Eeuo pipefail

readonly signingIdentity="MTMR Local Signing"
readonly loginKeychain="${HOME}/Library/Keychains/login.keychain-db"
readonly certificateConfiguration='[req]
distinguished_name = certificateName
x509_extensions = signingExtensions
prompt = no
[certificateName]
CN = MTMR Local Signing
[signingExtensions]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning'
dryRun=false
temporaryDirectory=""

step() { printf '==> %s\n' "$*"; }
fail() { printf 'make-signing-identity.sh: %s\n' "$*" >&2; exit 1; }
trap 'printf "make-signing-identity.sh: command failed at line %s\n" "$LINENO" >&2' ERR

runCommand() {
  if [[ "${dryRun}" == true ]]; then
    printf '  '
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

cleanup() {
  local exitStatus=$?
  if ! runCommand rm -f -- "${temporaryDirectory}/certificate.conf" \
    "${temporaryDirectory}/private-key.pem" "${temporaryDirectory}/certificate.pem" \
    "${temporaryDirectory}/identity.p12"; then
    printf 'make-signing-identity.sh: temporary file cleanup failed\n' >&2
    exitStatus=1
  fi
  if ! runCommand rmdir -- "${temporaryDirectory}"; then
    printf 'make-signing-identity.sh: temporary directory cleanup failed\n' >&2
    exitStatus=1
  fi
  exit "${exitStatus}"
}

checkExistingIdentity() {
  step "Refuse setup if an identity named ${signingIdentity} already exists (including untrusted identities)"
  if [[ "${dryRun}" == true ]]; then
    runCommand /usr/bin/security find-identity -p codesigning
    return
  fi
  local signingIdentities
  signingIdentities="$(/usr/bin/security find-identity -p codesigning)" || fail "could not list code-signing identities"
  if grep -Fq -- "\"${signingIdentity}\"" <<< "${signingIdentities}"; then
    fail "${signingIdentity} already exists; keeping the existing identity unchanged"
  fi
}

createIdentity() {
  local packagePassword
  step "Create a private temporary directory and random one-time PKCS#12 password"
  if [[ "${dryRun}" == true ]]; then
    runCommand mktemp -d
    temporaryDirectory='<temporary-directory>'
  else
    umask 077
    temporaryDirectory="$(mktemp -d)"
  fi
  trap cleanup EXIT
  if [[ "${dryRun}" == true ]]; then
    runCommand /usr/bin/openssl rand -hex 32
    packagePassword='<random-one-time-password>'
  else
    packagePassword="$(/usr/bin/openssl rand -hex 32)"
  fi
  step "Write ${temporaryDirectory}/certificate.conf"
  if [[ "${dryRun}" == true ]]; then
    printf '  printf '\''%%s\\n'\'' %q > %q\n' "${certificateConfiguration}" "${temporaryDirectory}/certificate.conf"
  else
    printf '%s\n' "${certificateConfiguration}" > "${temporaryDirectory}/certificate.conf"
  fi
  step "Create a self-signed RSA 2048 code-signing certificate valid for 10 years (3650 days)"
  runCommand /usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -config "${temporaryDirectory}/certificate.conf" \
    -keyout "${temporaryDirectory}/private-key.pem" -out "${temporaryDirectory}/certificate.pem"
  step "Package the certificate and private key with the one-time password"
  runCommand /usr/bin/openssl pkcs12 -export -name "${signingIdentity}" \
    -inkey "${temporaryDirectory}/private-key.pem" -in "${temporaryDirectory}/certificate.pem" \
    -out "${temporaryDirectory}/identity.p12" -passout "pass:${packagePassword}"
  step "Import into the login keychain, allowing /usr/bin/codesign to use the key"
  runCommand /usr/bin/security import "${temporaryDirectory}/identity.p12" \
    -k "${loginKeychain}" -f pkcs12 -P "${packagePassword}" -T /usr/bin/codesign
  step "Remove temporary certificate, private key, package, and configuration on exit"
}

main() {
  case "$#:$*" in
    0:) ;;
    1:--dry-run) dryRun=true ;;
    *) fail "usage: mtmr/make-signing-identity.sh [--dry-run]" ;;
  esac
  step "Create ${signingIdentity} in ${loginKeychain}; no trust settings will change"
  step 'Rollback: security delete-identity -c "MTMR Local Signing"'
  step 'macOS may show "codesign wants to use key"; choose Always Allow'
  # #COMPLETION_DRIVE: An untrusted self-signed identity should preserve TCC's designated requirement across rebuilds.
  # #SUGGEST_VERIFY: On this Mac, sign two rebuilds and confirm Accessibility survives without resetting it.
  checkExistingIdentity
  createIdentity
}

main "$@"
