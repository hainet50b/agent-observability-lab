#!/usr/bin/env bash
# seal.sh — edge content-sealing helper (sourced by agent-audit-core.sh).
# seal::body <recipients_file> <compress_min_bytes> <body_length>:
# plaintext body on stdin -> single-line base64(DER CMS) on stdout.
# Framing tag sealed under the cipher: 0x00 raw, 0x01 gzip. On any failure
# returns non-zero with no output, so the caller writes metadata-only.

SEAL_TIMEOUT_SECS=${SEAL_TIMEOUT_SECS:-2}

seal::body() {
  local recipients_file=$1 compress_min=${2:-0} body_len=${3:-0}
  [ -n "$recipients_file" ] && [ -f "$recipients_file" ] || return 1
  command -v openssl >/dev/null 2>&1 || return 1

  local -a runner=()
  command -v timeout >/dev/null 2>&1 && runner=(timeout "$SEAL_TIMEOUT_SECS")

  local out
  if [ "$compress_min" -gt 0 ] && [ "$body_len" -ge "$compress_min" ] && command -v gzip >/dev/null 2>&1; then
    out=$(
      set -o pipefail
      {
        printf '\x01'
        gzip -c
      } |
        "${runner[@]}" openssl cms -encrypt -aes256 -recip "$recipients_file" -binary -outform DER |
        openssl base64 -A
    ) || return 1
  else
    out=$(
      set -o pipefail
      {
        printf '\x00'
        cat
      } |
        "${runner[@]}" openssl cms -encrypt -aes256 -recip "$recipients_file" -binary -outform DER |
        openssl base64 -A
    ) || return 1
  fi

  [ -n "$out" ] || return 1
  printf '%s' "$out"
}
