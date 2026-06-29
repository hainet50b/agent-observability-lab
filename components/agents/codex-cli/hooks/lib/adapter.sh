#!/usr/bin/env bash
# shellcheck disable=SC2034

provider='openai'
agent_name='codex-cli'
CODEX_HOME=${CODEX_HOME:-$HOME/.codex}

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
