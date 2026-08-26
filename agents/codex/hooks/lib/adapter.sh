#!/usr/bin/env bash
# shellcheck disable=SC2034

provider='openai'
agent_name='codex'
CODEX_HOME=${CODEX_HOME:-$HOME/.codex}

# Relative-path candidates for config-provenance runtime_hash (T8), mirroring
# the render-time entries in agent-config/src/agents/codex.rs. `home_dir` is
# the local/project agent home (".codex"); `target_root` is unused for Codex
# (no sibling root file — `[mcp_servers.*]` is folded into config.toml, and
# auth.json is a place-time symlink/copy, not a rendered manifest entry).
audit_provenance_local_pairs() {
  home_dir=$1
  provenance_abs+=("$home_dir/.gitignore")
  provenance_rel+=(".codex/.gitignore")
  provenance_abs+=("$home_dir/config.toml")
  provenance_rel+=(".codex/config.toml")
  provenance_abs+=("$home_dir/hooks/agent-audit.conf")
  provenance_rel+=(".codex/hooks/agent-audit.conf")
  provenance_abs+=("$home_dir/hooks/agent-audit.sh")
  provenance_rel+=(".codex/hooks/agent-audit.sh")
  provenance_abs+=("$home_dir/hooks/lib/adapter.sh")
  provenance_rel+=(".codex/hooks/lib/adapter.sh")
  provenance_abs+=("$home_dir/hooks/lib/agent-audit-core.sh")
  provenance_rel+=(".codex/hooks/lib/agent-audit-core.sh")
  provenance_abs+=("$home_dir/hooks/lib/seal.sh")
  provenance_rel+=(".codex/hooks/lib/seal.sh")
  provenance_abs+=("$home_dir/hooks/recipient.pem")
  provenance_rel+=(".codex/hooks/recipient.pem")
}

# Same, for a managed cell (agent-config/src/agents/codex.rs managed_root /
# managed_entries). `managed_config.toml` here is the non-Windows path only —
# adapter.ps1 carries the %USERPROFILE% variant this hook flavor never runs
# under (Os::Windows always resolves to the .ps1 flavor).
audit_provenance_managed_pairs() {
  executor=$1
  managed_root=$2
  root_rel=${managed_root#/}
  provenance_abs+=("$managed_root/hooks/$executor/agent-audit.conf")
  provenance_rel+=("$root_rel/hooks/$executor/agent-audit.conf")
  provenance_abs+=("$managed_root/hooks/$executor/agent-audit.sh")
  provenance_rel+=("$root_rel/hooks/$executor/agent-audit.sh")
  provenance_abs+=("$managed_root/hooks/$executor/lib/adapter.sh")
  provenance_rel+=("$root_rel/hooks/$executor/lib/adapter.sh")
  provenance_abs+=("$managed_root/hooks/$executor/lib/agent-audit-core.sh")
  provenance_rel+=("$root_rel/hooks/$executor/lib/agent-audit-core.sh")
  provenance_abs+=("$managed_root/hooks/$executor/lib/seal.sh")
  provenance_rel+=("$root_rel/hooks/$executor/lib/seal.sh")
  provenance_abs+=("$managed_root/hooks/$executor/recipient.pem")
  provenance_rel+=("$root_rel/hooks/$executor/recipient.pem")
  provenance_abs+=("$managed_root/requirements.toml")
  provenance_rel+=("$root_rel/requirements.toml")
  provenance_abs+=("$managed_root/managed_config.toml")
  provenance_rel+=("$root_rel/managed_config.toml")
}

awk_org='function liftstr(str,key,   kk,p,ii,nn,c,out){
    kk="\"" key "\":\""; p=index(str,kk); if(p==0) return "";
    ii=p+length(kk); nn=length(str); out="";
    while(ii<=nn){ c=substr(str,ii,1);
      if(c=="\\"){ out=out c substr(str,ii+1,1); ii+=2; continue }
      if(c=="\"") break;
      out=out c; ii++ }
    return out }
  BEGIN{
    s=ENVIRON["ORGS"]; n=length(s);
    depth=0; instr=0; start=0; chosen=""; first="";
    for(i=1;i<=n;i++){ ch=substr(s,i,1);
      if(instr){ if(ch=="\\"){i++; continue} if(ch=="\""){instr=0} continue }
      if(ch=="\""){instr=1; continue}
      if(ch=="{"){ if(depth==0) start=i; depth++; continue }
      if(ch=="}"){ depth--; if(depth==0){ obj=substr(s,start,i-start+1);
          if(first=="") first=obj;
          if(chosen=="" && index(obj,"\"is_default\":true")>0) chosen=obj } continue } }
    obj=(chosen!="")?chosen:first;
    print liftstr(obj,"id");
    print liftstr(obj,"title") }'

derive_runtime_identity() {
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _ms=$(date -u +%3N 2>/dev/null)
  case $_ms in
  [0-9][0-9][0-9]) ts="${ts%Z}.${_ms}Z" ;;
  esac

  user_name=${USER:-${USERNAME:-$(id -un 2>/dev/null || echo "")}}
  user_id=$(whoami 2>/dev/null || echo "")

  host_hostname=${HOSTNAME:-}
  [ -n "$host_hostname" ] || host_hostname=$(hostname 2>/dev/null || echo "")
  [ -n "$host_hostname" ] || host_hostname=${COMPUTERNAME:-}
  host_name=$host_hostname

  auth_file="$CODEX_HOME/auth.json"
  account_id="" account_name="" account_email="" organization_id="" organization_name=""
  if [ -f "$auth_file" ]; then
    auth=$(cat "$auth_file" 2>/dev/null || echo "")
    account_id=$(json::string_field "$auth" account_id)
    id_token=$(json::string_field "$auth" id_token)
    if [ -n "$id_token" ] && command -v base64 >/dev/null 2>&1; then
      segment=$(printf '%s' "$id_token" | cut -d. -f2)
      padded=$(printf '%s' "$segment" | tr '_-' '/+')
      case $((${#padded} % 4)) in
      2) padded="${padded}==" ;;
      3) padded="${padded}=" ;;
      esac
      claims=$(printf '%s' "$padded" | base64 -d 2>/dev/null || echo "")
      if [ -n "$claims" ]; then
        account_name=$(json::string_field "$claims" name)
        account_email=$(json::string_field "$claims" email)
        orgs=$(json::raw_value "$claims" organizations)
        if [ -n "$orgs" ]; then
          {
            IFS= read -r organization_id
            IFS= read -r organization_name
          } <<EOF
$(ORGS="$orgs" awk "$awk_org")
EOF
        fi
      fi
    fi
  fi
}
