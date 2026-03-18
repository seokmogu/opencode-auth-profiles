#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

const HOME = os.homedir();
const OPENCODE_HOME = process.env.OPENCODE_HOME || path.join(HOME, ".local/share/opencode");
const PROFILES_DIR = process.env.OPENCODE_PROFILES_HOME || path.join(OPENCODE_HOME, "profiles");
const MANIFEST = path.join(PROFILES_DIR, "manifest.json");
const AUTH_FILE = path.join(OPENCODE_HOME, "auth.json");
const CLIENT_ID = process.env.ANTHROPIC_OAUTH_CLIENT_ID || "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const TOKEN_ENDPOINT = "https://console.anthropic.com/v1/oauth/token";
const REFRESH_THRESHOLD_MS = 2 * 3600 * 1000;

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJsonAtomic(file, data) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(tmp, `${JSON.stringify(data, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function getManifest() {
  return readJson(MANIFEST);
}

function getActiveMap(manifest) {
  return Object.fromEntries(Object.entries(manifest.providers || {}).map(([provider, info]) => [provider, info.active]));
}

function getProfilePath(provider, name) {
  return path.join(PROFILES_DIR, provider, `${name}.json`);
}

function nowMs() {
  return Date.now();
}

function hoursRemaining(expires) {
  return (expires - nowMs()) / 3600000;
}

async function refreshAnthropicCredential(refreshToken) {
  const response = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: CLIENT_ID,
    }),
  });
  const text = await response.text();
  let body = null;
  try {
    body = JSON.parse(text);
  } catch {
    body = null;
  }
  if (!response.ok) {
    const message = body?.error_description || body?.error?.message || text || `HTTP ${response.status}`;
    throw new Error(`refresh failed: ${response.status} ${message}`);
  }
  return {
    type: "oauth",
    access: body.access_token,
    refresh: body.refresh_token,
    expires: nowMs() + body.expires_in * 1000,
  };
}

async function refreshAnthropicProfile(name, options = {}) {
  const manifest = getManifest();
  const activeMap = getActiveMap(manifest);
  const profilePath = getProfilePath("anthropic", name);
  const current = readJson(profilePath);
  const isActive = activeMap.anthropic === name;
  if (!current.refresh) {
    return { ok: true, skipped: true, reason: "no-refresh-token", name, isActive };
  }
  const remaining = hoursRemaining(current.expires || 0);
  if (!options.force && remaining > REFRESH_THRESHOLD_MS / 3600000) {
    return { ok: true, skipped: true, reason: `fresh:${remaining.toFixed(1)}h`, name, isActive };
  }
  const refreshed = await refreshAnthropicCredential(current.refresh);
  const updated = {
    ...current,
    ...refreshed,
    lastRefreshedAt: nowMs(),
    refreshSource: "direct-api",
    refreshCount: (current.refreshCount || 0) + 1,
    lastError: null,
  };
  writeJsonAtomic(profilePath, updated);
  if (isActive) {
    const auth = readJson(AUTH_FILE);
    auth.anthropic = {
      type: updated.type,
      access: updated.access,
      refresh: updated.refresh,
      expires: updated.expires,
    };
    writeJsonAtomic(AUTH_FILE, auth);
  }
  return { ok: true, skipped: false, name, isActive, remaining: hoursRemaining(updated.expires) };
}

async function refreshAllAnthropic({ force = false, includeActive = false } = {}) {
  const manifest = getManifest();
  const activeMap = getActiveMap(manifest);
  const names = Object.keys(manifest.providers?.anthropic?.profiles || {});
  let hasFailure = false;
  for (const name of names) {
    const isActive = activeMap.anthropic === name;
    if (isActive && !includeActive) {
      const profile = readJson(getProfilePath("anthropic", name));
      console.log(`SKIP anthropic/${name}: active profile (${hoursRemaining(profile.expires || 0).toFixed(1)}h remaining)`);
      continue;
    }
    try {
      const result = await refreshAnthropicProfile(name, { force });
      if (result.skipped) console.log(`SKIP anthropic/${name}: ${result.reason}`);
      else console.log(`OK   anthropic/${name}: refreshed (${result.remaining.toFixed(1)}h remaining)`);
    } catch (error) {
      hasFailure = true;
      const profilePath = getProfilePath("anthropic", name);
      const current = readJson(profilePath);
      current.lastError = String(error.message || error);
      writeJsonAtomic(profilePath, current);
      console.log(`FAIL anthropic/${name}: ${error.message || error}`);
    }
  }
  return hasFailure ? 1 : 0;
}

function printHealth() {
  const manifest = getManifest();
  const activeMap = getActiveMap(manifest);
  console.log("=== All Profile Health ===");
  for (const [provider, info] of Object.entries(manifest.providers || {})) {
    for (const [name, meta] of Object.entries(info.profiles || {})) {
      const profilePath = getProfilePath(provider, name);
      if (!fs.existsSync(profilePath)) {
        console.log(`  ${provider}/${name} missing  ❌  ${meta.label || ""}`);
        continue;
      }
      const data = readJson(profilePath);
      const activeLabel = activeMap[provider] === name ? "active" : "inactive";
      if (data.type === "oauth") {
        const remain = hoursRemaining(data.expires || 0);
        const status = remain > 1 ? "✅" : remain > 0 ? "⚠️" : "❌";
        const source = data.refreshSource || (activeLabel === "active" ? "opencode" : "snapshot");
        const errorSuffix = data.lastError ? `  ERROR=${data.lastError}` : "";
        console.log(`  ${provider}/${name}`.padEnd(28) + `${remain.toFixed(1)}h`.padStart(7) + `  ${status}  [${activeLabel}]  ${source}  ${meta.label || ""}${errorSuffix}`);
      } else if (data.key) {
        console.log(`  ${provider}/${name}`.padEnd(28) + `      ∞  ✅  [${activeLabel}]  static  ${meta.label || ""}`);
      }
    }
  }
  console.log("\n=== Server Readiness ===");
  for (const [server, mapping] of Object.entries(manifest.servers || {})) {
    const parts = [];
    for (const [provider, name] of Object.entries(mapping || {})) {
      const profilePath = getProfilePath(provider, name);
      if (!fs.existsSync(profilePath)) {
        parts.push(`${provider}/${name} missing ❌`);
        continue;
      }
      const data = readJson(profilePath);
      if (data.type === "oauth") {
        const remain = hoursRemaining(data.expires || 0);
        const status = remain > 1 ? "✅" : remain > 0 ? "⚠️" : "❌";
        parts.push(`${provider}/${name} ${remain.toFixed(1)}h ${status}`);
      } else if (data.key) {
        parts.push(`${provider}/${name} ∞ ✅`);
      }
    }
    console.log(`  ${server}: ${parts.join(" | ")}`);
  }
}

async function verifyRemote(server) {
  const remoteScript = `import json, pathlib, urllib.request, urllib.error
auth = json.load(open(pathlib.Path.home()/'.local/share/opencode/auth.json'))
out = {}
for provider, data in auth.items():
    if not isinstance(data, dict):
        continue
    if provider != 'anthropic' or data.get('type') != 'oauth':
        out[provider] = {'status': 'present'}
        continue
    token = data.get('access', '')
    req = urllib.request.Request(
        'https://api.anthropic.com/v1/models?beta=true',
        headers={
            'authorization': 'Bearer ' + token,
            'anthropic-version': '2023-06-01',
            'anthropic-beta': 'oauth-2025-04-20',
            'user-agent': 'claude-cli/2.1.2 (external, cli)',
        },
        method='GET',
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.loads(resp.read().decode())
        out[provider] = {'status': 'ok', 'models': len(body.get('data', [])) if isinstance(body, dict) else 0}
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode()
        except Exception:
            body = ''
        out[provider] = {'status': f'oauth_http_{e.code}', 'body': body[:200]}
print(json.dumps(out))`;

  return await new Promise((resolve) => {
    const child = spawn("ssh", ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes", server, "python3", "-"], { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let finished = false;
    const timer = setTimeout(() => {
      if (!finished) child.kill("SIGTERM");
    }, 30000);
    child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
    child.on("close", (code) => {
      clearTimeout(timer);
      finished = true;
      if (code !== 0) {
        resolve({ server, error: stderr.trim() || `ssh_exit_${code}` });
        return;
      }
      try {
        resolve({ server, data: JSON.parse(stdout) });
      } catch {
        resolve({ server, error: "invalid-json" });
      }
    });
    child.stdin.write(remoteScript);
    child.stdin.end();
  });
}

async function verifyRemotes(serverFilter = null) {
  const manifest = getManifest();
  const servers = Object.keys(manifest.servers || {}).filter((s) => !serverFilter || s === serverFilter);
  console.log("=== Remote Verification ===");
  let failed = false;
  for (const server of servers) {
    const result = await verifyRemote(server);
    if (result.error) {
      failed = true;
      console.log(`  ${server}: ❌ ${result.error}`);
      continue;
    }
    const mapping = manifest.servers?.[server] || {};
    for (const [provider, info] of Object.entries(result.data || {})) {
      const profile = mapping[provider] || "?";
      const status = info.status || "unknown";
      const ok = status === "ok" || status === "present";
      if (!ok) failed = true;
      const icon = ok ? "✅" : "❌";
      const extra = info.models ? ` models=${info.models}` : info.body ? ` ${info.body}` : "";
      console.log(`  ${server}: ${provider.padEnd(12)} ${String(profile).padEnd(15)} ${icon} ${status}${extra}`);
    }
  }
  return failed ? 1 : 0;
}

const [, , command, ...rest] = process.argv;

if (command === "refresh-all") {
  const force = rest.includes("--force");
  const includeActive = rest.includes("--include-active");
  process.exit(await refreshAllAnthropic({ force, includeActive }));
}

if (command === "refresh") {
  const providerIndex = rest.indexOf("--provider");
  const nameIndex = rest.indexOf("--name");
  const force = rest.includes("--force");
  const provider = providerIndex >= 0 ? rest[providerIndex + 1] : null;
  const name = nameIndex >= 0 ? rest[nameIndex + 1] : null;
  if (provider !== "anthropic" || !name) {
    console.error("Usage: oc-refresh.mjs refresh --provider anthropic --name <profile> [--force]");
    process.exit(1);
  }
  try {
    const result = await refreshAnthropicProfile(name, { force });
    if (result.skipped) console.log(`SKIP anthropic/${name}: ${result.reason}`);
    else console.log(`OK   anthropic/${name}: refreshed (${result.remaining.toFixed(1)}h remaining)`);
    process.exit(0);
  } catch (error) {
    console.error(`FAIL anthropic/${name}: ${error.message || error}`);
    process.exit(1);
  }
}

if (command === "health") {
  printHealth();
  process.exit(0);
}

if (command === "verify-remotes") {
  const serverIndex = rest.indexOf("--server");
  const server = serverIndex >= 0 ? rest[serverIndex + 1] : null;
  process.exit(await verifyRemotes(server));
}

console.error("Usage: oc-refresh.mjs <refresh-all|refresh|health|verify-remotes>");
process.exit(1);
