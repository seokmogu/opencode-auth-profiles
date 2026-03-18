#!/usr/bin/env bash

OPENCODE_HOME="${OPENCODE_HOME:-$HOME/.local/share/opencode}"
OC_PROFILES_DIR="${OPENCODE_PROFILES_HOME:-$OPENCODE_HOME/profiles}"
OC_AUTH_FILE="$OPENCODE_HOME/auth.json"
OC_MANIFEST="$OC_PROFILES_DIR/manifest.json"

_oc_py() {
  python3 -c "
import json, sys, os, time
MANIFEST = '$OC_MANIFEST'
PROFILES = '$OC_PROFILES_DIR'
AUTH = '$OC_AUTH_FILE'
PROVIDERS = ['anthropic', 'openai', 'google', 'litellm']
def load_manifest():
    with open(MANIFEST) as f:
        return json.load(f)
def load_auth():
    if not os.path.exists(AUTH):
        return {}
    with open(AUTH) as f:
        return json.load(f)
def save_manifest(m):
    with open(MANIFEST, 'w') as f:
        json.dump(m, f, indent=2, ensure_ascii=False)
def assemble_auth(provider_map, current_auth=None, active_map=None):
    current_auth = current_auth or {}
    active_map = active_map or {}
    auth = {}
    for provider in PROVIDERS:
        profile_name = provider_map.get(provider)
        if not profile_name:
            continue
        if active_map.get(provider) == profile_name and provider in current_auth:
            auth[provider] = current_auth[provider]
            continue
        path = os.path.join(PROFILES, provider, f'{profile_name}.json')
        if os.path.exists(path):
            with open(path) as f:
                data = json.load(f)
            if data.get('type') == 'oauth' and data.get('expires', 0) < int(time.time() * 1000):
                raise SystemExit(f'Blocked: {provider}/{profile_name} oauth snapshot is expired. Refresh locally first.')
            auth[provider] = data
    return auth
def to_access_only_auth(auth):
    remote = {}
    for provider, data in auth.items():
        if not isinstance(data, dict):
            continue
        if data.get('type') == 'oauth':
            if data.get('expires', 0) < int(time.time() * 1000):
                raise SystemExit(f'Blocked: {provider} current oauth access token is expired. Refresh locally first.')
            remote[provider] = {'type': 'oauth', 'access': data.get('access', ''), 'expires': data.get('expires')}
        else:
            remote[provider] = data
    return remote
def get_active_map(m):
    return {p: info['active'] for p, info in m.get('providers', {}).items() if 'active' in info}
$1
"
}

# oc-whoami: Show current active profiles per provider
oc-whoami() {
  _oc_py "m=load_manifest(); [print(f'  {p:12s} {i.get(\"active\",\"?\")} ({i.get(\"profiles\",{}).get(i.get(\"active\",\"\"),{}).get(\"label\",\"\")})') for p,i in m.get('providers',{}).items()]"
}

# oc-save <provider> <name> [label]: Save current auth.json provider section as profile
oc-save() {
  local provider="$1"
  local name="$2"
  local label="${3:-$name}"
  if [[ -z "$provider" || -z "$name" ]]; then
    echo "Usage: oc-save <provider> <name> [label]"
    return 1
  fi
  _oc_py "provider='$provider'; name='$name'; label='$label'; auth=load_auth();
if provider not in auth: sys.exit('Provider not found in auth.json');
os.makedirs(os.path.join(PROFILES, provider), exist_ok=True)
with open(os.path.join(PROFILES, provider, f'{name}.json'), 'w') as f: json.dump(auth[provider], f, indent=2)
m=load_manifest(); m.setdefault('providers', {}).setdefault(provider, {'profiles': {}, 'active': name}); m['providers'][provider]['profiles'][name]={'label': label}; m['providers'][provider]['active']=name; save_manifest(m); print(f'Saved: {provider}/{name} ({label})')"
}

# oc-sync [provider...]: Save current auth.json back to active provider profiles
oc-sync() {
  local providers=("$@")
  local arg_str="${providers[*]}"
  _oc_py "m=load_manifest(); auth=load_auth(); targets='$arg_str'.split() if '$arg_str'.strip() else PROVIDERS
for provider in targets:
    if provider not in auth: continue
    active=m.get('providers', {}).get(provider, {}).get('active')
    if not active: continue
    os.makedirs(os.path.join(PROFILES, provider), exist_ok=True)
    with open(os.path.join(PROFILES, provider, f'{active}.json'), 'w') as f: json.dump(auth[provider], f, indent=2)
    print(f'Synced: {provider}/{active}')"
}

# oc-refresh: Refresh inactive Anthropic OAuth profiles locally
oc-refresh() {
  local force=""
  local include_active=""
  local profile=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force="--force"; shift ;;
      --include-active) include_active="--include-active"; shift ;;
      --profile) profile="${2##*/}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$profile" ]]; then
    node "$OC_PROFILES_DIR/oc-refresh.mjs" refresh --provider anthropic --name "$profile" $force
  else
    node "$OC_PROFILES_DIR/oc-refresh.mjs" refresh-all $force $include_active
  fi
}

# oc-health: Show health for all local profiles and server readiness
oc-health() {
  node "$OC_PROFILES_DIR/oc-refresh.mjs" health
}

# oc-verify: Verify deployed remote tokens are actually usable
oc-verify() {
  if [[ -n "${1:-}" ]]; then
    node "$OC_PROFILES_DIR/oc-refresh.mjs" verify-remotes --server "$1"
  else
    node "$OC_PROFILES_DIR/oc-refresh.mjs" verify-remotes
  fi
}

# oc-apply [--provider name]...: Apply provider profiles to auth.json
oc-apply() {
  local args=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) args="$args ALL=$2"; shift 2 ;;
      --*) args="$args ${1#--}=$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _oc_py "args_str='$args'.strip(); overrides={}; [overrides.setdefault(k, v) for k,v in [pair.split('=',1) for pair in args_str.split()]] if args_str else None
m=load_manifest(); active_map=get_active_map(m); current_auth=load_auth()
if 'ALL' in overrides:
    for p in PROVIDERS:
        if os.path.exists(os.path.join(PROFILES, p, f'{overrides[\"ALL\"]}.json')): active_map[p]=overrides['ALL']
    del overrides['ALL']
for provider, name in overrides.items():
    if provider in PROVIDERS: active_map[provider]=name
auth=assemble_auth(active_map, current_auth=current_auth, active_map=get_active_map(m))
with open(AUTH, 'w') as f: json.dump(auth, f, indent=2)
for provider, name in active_map.items(): m.setdefault('providers', {}).setdefault(provider, {})['active']=name
save_manifest(m)
print('Applied:'); [print(f'  {p:12s} -> {active_map.get(p,\"?\")} ({m.get(\"providers\",{}).get(p,{}).get(\"profiles\",{}).get(active_map.get(p,\"\"),{}).get(\"label\",\"\")})') for p in PROVIDERS]"
}

# oc-list: List all profiles per provider
oc-list() {
  _oc_py "m=load_manifest();
for provider, info in m.get('providers', {}).items():
    active=info.get('active',''); profiles=info.get('profiles',{})
    if not profiles: continue
    print(f'{provider}:')
    for name, meta in profiles.items():
        marker='*' if name == active else ' '
        print(f'  {marker} {name:15s} {meta.get(\"label\",\"\")}')"
}

# oc-deploy <server>: Deploy assembled auth.json to remote server
oc-deploy() {
  local server="$1"
  local mode="access-only"
  if [[ "$1" == "--full-oauth" ]]; then
    mode="full-oauth"
    shift
    server="$1"
  fi
  if [[ "$server" == "--all" ]]; then
    _oc_deploy_all "$mode"
    return $?
  fi
  if [[ -z "$server" ]]; then
    echo "Usage: oc-deploy <server>"
    echo "       oc-deploy --all"
    echo "       oc-deploy --full-oauth <server>"
    return 1
  fi
  _oc_py "m=load_manifest(); server_map=m.get('servers', {}).get('$server'); current_auth=load_auth(); active_map=server_map if server_map else get_active_map(m); auth=assemble_auth(active_map, current_auth=current_auth, active_map=get_active_map(m));
if '$mode' == 'access-only': auth=to_access_only_auth(auth)
import tempfile; tmp=tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False); json.dump(auth, tmp, indent=2); tmp.close(); print(f'TMPFILE={tmp.name}')
for p in PROVIDERS:
    name=active_map.get(p,'?'); source='current-auth' if get_active_map(m).get(p)==name and p in current_auth else 'profile'; deploy_kind='access-only' if '$mode' == 'access-only' and auth.get(p,{}).get('type') == 'oauth' else 'full'; print(f'  {p:12s} -> {name} [{source}, {deploy_kind}]')" | {
    local tmpfile=""
    while IFS= read -r line; do
      if [[ "$line" == TMPFILE=* ]]; then tmpfile="${line#TMPFILE=}"; else echo "$line"; fi
    done
    if [[ -n "$tmpfile" ]]; then
      ssh "$server" "mkdir -p ~/.local/share/opencode" && scp -q "$tmpfile" "$server:~/.local/share/opencode/auth.json" && echo "  Deployed to $server" || echo "  Failed"
      rm -f "$tmpfile"
    fi
  }
}

_oc_deploy_all() {
  local mode="${1:-access-only}"
  _oc_py "m=load_manifest(); [print(server) for server in m.get('servers', {})]" | while IFS= read -r server; do
    if [[ "$mode" == "full-oauth" ]]; then oc-deploy --full-oauth "$server"; else oc-deploy "$server"; fi
  done
}

# oc-export-openclaw-auth <file>: Export access-only OpenClaw auth-profiles
oc-export-openclaw-auth() {
  local outfile="$1"
  if [[ -z "$outfile" ]]; then
    echo "Usage: oc-export-openclaw-auth <file>"
    return 1
  fi
  _oc_py "m=load_manifest(); current_auth=load_auth(); auth=assemble_auth(get_active_map(m), current_auth=current_auth, active_map=get_active_map(m)); auth=to_access_only_auth(auth)
anthropic=auth.get('anthropic', {}); openai=auth.get('openai', {}); profiles={'version': 1, 'profiles': {}, 'lastGood': {}, 'usageStats': {}}
if anthropic.get('access'):
    profiles['profiles']['anthropic:manual']={'type':'token','provider':'anthropic','token':anthropic['access']}
    profiles['profiles']['anthropic:default']={'type':'token','provider':'anthropic','token':anthropic['access']}
    profiles['lastGood']['anthropic']='anthropic:default'
if openai.get('access'):
    profiles['profiles']['openai-codex:chatgpt-pro']={'type':'token','provider':'openai-codex','token':openai['access']}
    profiles['lastGood']['openai-codex']='openai-codex:chatgpt-pro'
with open('$outfile', 'w') as f: json.dump(profiles, f, indent=2)
print(f'Exported OpenClaw auth: $outfile')"
}

# oc-map <server> [--provider name]...: Map server to provider profiles
oc-map() {
  local server="$1"
  shift
  if [[ -z "$server" ]]; then
    echo "Usage: oc-map <server> --all <name>"
    echo "       oc-map <server> --anthropic <name> --openai <name>"
    return 1
  fi
  local args=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) args="$args ALL=$2"; shift 2 ;;
      --*) args="$args ${1#--}=$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  _oc_py "args_str='$args'.strip(); mapping={}; [mapping.setdefault(k, v) for k,v in [pair.split('=',1) for pair in args_str.split()]] if args_str else None
m=load_manifest()
if 'ALL' in mapping:
    for p in PROVIDERS:
        if os.path.exists(os.path.join(PROFILES, p, f'{mapping[\"ALL\"]}.json')): mapping[p]=mapping['ALL']
    del mapping['ALL']
server_map={p: v for p, v in mapping.items() if p in PROVIDERS}; m.setdefault('servers', {})['$server']=server_map; save_manifest(m)
print(f'Mapped $server:'); [print(f'  {p:12s} -> {name}') for p, name in server_map.items()]"
}

_oc_check_remotes() {
  local cache="$OC_PROFILES_DIR/.remote-status.json"
  local tmp_py
  tmp_py=$(mktemp)
  cat > "$tmp_py" <<'PY'
import json
import pathlib
import time
d = json.load(open(pathlib.Path.home() / '.local/share/opencode/auth.json'))
now = int(time.time() * 1000)
for p, v in d.items():
    if not isinstance(v, dict):
        continue
    if v.get('type') == 'oauth':
        remain = round(max(0, (v.get('expires', 0) - now)) / 3600000, 1)
        print(p, v.get('type', '?'), remain, ('refresh' in v))
    else:
        print(p, v.get('type', '?'), -1, False)
PY
  local servers_list
  servers_list=$(python3 -c "import json; m=json.load(open('$OC_MANIFEST')); [print(s) for s in m.get('servers',{})]")
  echo "{" > "$cache"
  local first=true
  while IFS= read -r server; do
    [[ -z "$server" ]] && continue
    $first || echo "," >> "$cache"
    first=false
    local result=""
    if ! result=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$server" python3 - < "$tmp_py" 2>/dev/null); then
      printf '"%s": {"error": "unreachable"}' "$server" >> "$cache"
    else
      printf '"%s": {"providers": [' "$server" >> "$cache"
      local line_first=true
      while IFS= read -r line; do
        $line_first || printf ',' >> "$cache"
        line_first=false
        printf '"%s"' "$line" >> "$cache"
      done <<< "$result"
      printf ']}' >> "$cache"
    fi
  done <<< "$servers_list"
  echo "}" >> "$cache"
  rm -f "$tmp_py"
}

# oc-status: Show profiles, servers, token health, and scheduler
oc-status() {
  _oc_check_remotes
  _oc_py "import subprocess
m=load_manifest(); auth=load_auth(); now=int(time.time() * 1000)
print('=== Local Token Health ===')
for provider in PROVIDERS:
    data=auth.get(provider, {}); active=m.get('providers', {}).get(provider, {}).get('active', '?'); label=m.get('providers', {}).get(provider, {}).get('profiles', {}).get(active, {}).get('label', ''); t=data.get('type', '?')
    if t == 'oauth':
        exp=data.get('expires', 0); remain_h=max(0, (exp - now) / 3600000); status='✅' if remain_h > 1 else ('⚠️' if remain_h > 0 else '❌'); print(f'  {provider:12s} {active:15s} {t:6s}  {remain_h:5.1f}h  {status}  {label}')
    elif 'key' in data or t == 'key':
        print(f'  {provider:12s} {active:15s} {\"key\":6s}      ∞  ✅  {label}')
print(); print('=== Remote Token Health ===')
remote_cache=os.path.join(PROFILES, '.remote-status.json')
if os.path.exists(remote_cache):
    with open(remote_cache) as f: remote_data=json.load(f)
    servers=m.get('servers', {})
    for server, mapping in servers.items():
        srv=remote_data.get(server, {})
        if srv.get('error'):
            print(f'  {server}: ❌ {srv[\"error\"]}')
            continue
        for line in srv.get('providers', []):
            parts=line.split()
            if len(parts) < 4: continue
            provider, kind, remain_s, has_refresh_s=parts[0], parts[1], parts[2], parts[3]
            remain=float(remain_s); has_refresh=has_refresh_s == 'True'; name=mapping.get(provider, '?') if isinstance(mapping, dict) else '?'
            if kind != 'oauth':
                print(f'  {server}: {provider:12s} {name:15s} key        ∞  ✅')
            else:
                status='✅' if remain > 1 else ('⚠️' if remain > 0 else '❌'); mode='full' if has_refresh else 'access-only'; print(f'  {server}: {provider:12s} {name:15s} oauth  {remain:5.1f}h  {status}  [{mode}]')
print(); print('=== Token Push Scheduler ===')
try:
    r=subprocess.run(['launchctl','list','com.opencode.token-push'], capture_output=True, text=True, timeout=5)
    print('  Status: ✅ registered' if r.returncode == 0 else '  Status: ❌ not registered')
except Exception:
    print('  Status: ? unknown')
log_path=os.path.join(PROFILES, 'token-push.log')
if os.path.exists(log_path):
    with open(log_path) as f: lines=f.readlines()
    last=[l.strip() for l in lines if 'completed' in l]
    if last: print(f'  Last push: {last[-1]}')"
}
