#!/usr/bin/env bash
# decrypt.sh — recover a sealed body at the center.
#
# Reads an encrypted_text value (single-line base64 of a DER CMS message) on
# stdin and writes the recovered plaintext body to stdout. Tries each epoch's
# private key (or only the one named) until one opens the message.
#
# Usage:
#   decrypt.sh [epoch] < field.b64
#   jq -r '._source.agent_audit.user_prompt.encrypted_text' doc.json | decrypt.sh
#
# Exit status: 0 if decrypted; non-zero if no key opened it.

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
sealing_dir=$(cd "$script_dir/.." && pwd)
priv_root="$sealing_dir/private"

log() { printf '%s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

command -v openssl >/dev/null 2>&1 || die "openssl not found"

epoch=${1:-}

# collect candidate private keys
keys=()
if [ -n "$epoch" ]; then
  k="$priv_root/$epoch/private.key"
  [ -f "$k" ] || die "no private key for epoch '$epoch' at $k"
  keys+=("$k")
else
  for k in "$priv_root"/*/private.key; do
    [ -f "$k" ] && keys+=("$k")
  done
  [ "${#keys[@]}" -gt 0 ] || die "no private keys under $priv_root"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# stdin (base64 text) -> DER bytes. Binary stays in files, never in a shell var.
cat >"$tmp/in.b64"
[ -s "$tmp/in.b64" ] || die "empty input on stdin"
base64 -d "$tmp/in.b64" >"$tmp/in.der" 2>/dev/null || die "input is not valid base64"

for k in "${keys[@]}"; do
  if openssl cms -decrypt -inform DER -in "$tmp/in.der" -inkey "$k" -binary >"$tmp/framed" 2>/dev/null; then
    epoch_used=$(basename "$(dirname "$k")")
    tag=$(head -c1 "$tmp/framed" | od -An -tu1 | tr -d ' ')
    case "$tag" in
    0) tail -c +2 "$tmp/framed" ;;
    1) tail -c +2 "$tmp/framed" | gunzip -c ;;
    *) die "decrypted with epoch '$epoch_used' but found unknown framing tag '$tag' (expected 0 or 1)" ;;
    esac
    log "decrypted with epoch '$epoch_used' (framing tag $tag)"
    exit 0
  fi
done

die "no private key opened this message (tried: ${keys[*]})"
