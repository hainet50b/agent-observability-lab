#!/usr/bin/env bash
# new-recipient.sh — issue one rotation epoch's sealing key pair (center tool).
#
# Usage: new-recipient.sh <epoch>
#   <epoch>  rotation label, e.g. 20260624-0001 — becomes the cert CN and the
#            seal.key_id stored cleartext alongside every body sealed to it.
#
# Emits (relative to the sealing/ directory):
#   recipients/<epoch>/recipient.pem   public cert, PEM  — Linux/macOS edges
#   recipients/<epoch>/recipient.cer   public cert, DER  — Windows edges
#   private/<epoch>/private.key        PRIVATE key — guard at the center, never distribute

set -euo pipefail

DAYS=1825     # cert validity (~5 years)
KEY_BITS=3072 # RSA-3072

script_dir=$(cd "$(dirname "$0")" && pwd)
sealing_dir=$(cd "$script_dir/.." && pwd)

log() { printf '%s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

[ "$#" -eq 1 ] || die "usage: $(basename "$0") <epoch>   e.g. 20260624-0001"
epoch=$1
case $epoch in
'') die "epoch must not be empty" ;;
*[!A-Za-z0-9._-]*) die "epoch '$epoch' has invalid characters (allowed: A-Z a-z 0-9 . _ -)" ;;
esac

command -v openssl >/dev/null 2>&1 || die "openssl not found"

cnf_file="$sealing_dir/recipient.cnf"
[ -f "$cnf_file" ] || die "missing cert config at $cnf_file"

pub_dir="$sealing_dir/recipients/$epoch"
key_dir="$sealing_dir/private/$epoch"
key_file="$key_dir/private.key"
pem_file="$pub_dir/recipient.pem"
cer_file="$pub_dir/recipient.cer"

[ -e "$key_file" ] && die "epoch '$epoch' already exists at $key_file — refusing to overwrite (would orphan everything sealed to it)"

mkdir -p "$pub_dir" "$key_dir"

# issue keypair: private.key (secret) + recipient.pem (public)
SEAL_EPOCH="$epoch" openssl req -x509 -newkey "rsa:$KEY_BITS" -nodes -days "$DAYS" \
  -keyout "$key_file" -out "$pem_file" -config "$cnf_file"

# PEM cert -> DER cert, for the Windows edge
openssl x509 -in "$pem_file" -outform DER -out "$cer_file"

chmod 600 "$key_file" 2>/dev/null || true

log ""
log "issued epoch '$epoch':"
log "  public  (distribute via the config bundle):"
log "    $pem_file   # Linux/macOS edges"
log "    $cer_file   # Windows edges"
log "  private (guard at the center, NEVER distribute):"
log "    $key_file"
log ""
log "next: set seal.key_id=$epoch and point seal.recipients_file at the distributed public cert."
