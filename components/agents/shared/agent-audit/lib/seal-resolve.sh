#!/usr/bin/env bash

seal_resolve::cn_epoch() {
  openssl x509 -noout -subject -in "$1" 2>/dev/null |
    sed -n 's/.*CN[[:space:]]*=[[:space:]]*agent-audit-recipient-\([^,/]*\).*/\1/p'
}

seal_resolve::resolve() {
  local recipients_root=$1 epoch=$2 override=$3 up_content=$4 tc_content=$5
  local want=0
  if [ "$up_content" = encrypted ] || [ "$tc_content" = encrypted ]; then
    want=1
  fi
  if [ "$want" -eq 1 ] && [ -z "$epoch" ]; then
    printf 'FAIL: content=encrypted requires agent_audit.seal.epoch\n' >&2
    return 1
  fi
  [ -n "$epoch" ] || {
    printf '\t'
    return 0
  }
  local src=${override:-$recipients_root/$epoch/recipient.pem}
  case $src in
  */private/*)
    printf 'FAIL: seal recipient must not be under sealing/private/: %s\n' "$src" >&2
    return 1
    ;;
  esac
  [ -f "$src" ] || {
    printf 'FAIL: recipient cert not found for epoch %s at %s\n' "$epoch" "$src" >&2
    return 1
  }
  command -v openssl >/dev/null 2>&1 || {
    printf 'FAIL: openssl required to verify recipient cert\n' >&2
    return 1
  }
  local cn
  cn=$(seal_resolve::cn_epoch "$src")
  [ "$cn" = "$epoch" ] || {
    printf 'FAIL: recipient cert CN epoch %s != seal.epoch %s (%s)\n' "${cn:-<none>}" "$epoch" "$src" >&2
    return 1
  }
  printf '%s\t%s' "$src" "$epoch"
}
