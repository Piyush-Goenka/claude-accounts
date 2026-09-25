// claude-switch: per-window Claude Code accounts for VS Code.
// Architecture (see plan.md in the claude-accounts repo): a wrapper script,
// registered via the claudeCode.claudeProcessWrapper setting, picks
// CLAUDE_CONFIG_DIR per spawn from map.json (project folder -> profile).
// This extension bootstraps the wrapper, shows the current account in the
// status bar, and lets the user switch or add accounts from a QuickPick.

const vscode = require('vscode');
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const https = require('https');

const EXCLUDE = new Set(['science']); // ~/.claude-* dirs that are not accounts
const SHARED_FILES = ['projects', 'history.jsonl', 'settings.json', 'CLAUDE.md', 'skills', 'plugins'];
const USAGE_TTL_MS = 5 * 60 * 1000;

let output;
let statusItem;
let wrapperPath;
let mapPath;
let usageCachePath;
let pendingRefresh = null; // per-window in-flight guard

function log(msg) {
  try { output.appendLine(`${new Date().toISOString()} ${msg}`); } catch (e) { /* ignore */ }
}

// ── small fs/json helpers ──────────────────────────────────────────

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return null; }
}

function canonical(p) {
  try { return fs.realpathSync(p).normalize('NFC'); } catch (e) { return path.resolve(p).normalize('NFC'); }
}

// ── profiles ───────────────────────────────────────────────────────

function profiles() {
  const home = os.homedir();
  const list = [{ name: 'default', dir: path.join(home, '.claude'), cfg: path.join(home, '.claude.json') }];
  let entries = [];
  try { entries = fs.readdirSync(home); } catch (e) { /* ignore */ }
  for (const e of entries.sort()) {
    if (!e.startsWith('.claude-')) continue;
    const name = e.slice('.claude-'.length);
    if (EXCLUDE.has(name)) continue;
    const dir = path.join(home, e);
    try { if (!fs.statSync(dir).isDirectory()) continue; } catch (err) { continue; }
    list.push({ name, dir, cfg: path.join(dir, '.claude.json') });
  }
  return list;
}

function keychainService(profile) {
  if (profile.name === 'default') return 'Claude Code-credentials';
  const hash = crypto.createHash('sha256').update(profile.dir.normalize('NFC')).digest('hex').slice(0, 8);
  return `Claude Code-credentials-${hash}`;
}

function readCred(profile) {
  return new Promise((resolve) => {
    cp.execFile('security', ['find-generic-password', '-s', keychainService(profile), '-w'],
      { timeout: 5000 }, (err, stdout) => {
        if (err) return resolve(null);
        try { resolve(JSON.parse(stdout.trim()).claudeAiOauth || null); } catch (e) { resolve(null); }
      });
  });
}

// ── usage ──────────────────────────────────────────────────────────

function fetchUsage(token) {
  return new Promise((resolve) => {
    const req = https.get('https://api.anthropic.com/api/oauth/usage', {
      headers: {
        'Authorization': `Bearer ${token}`,
        'anthropic-beta': 'oauth-2025-04-20',
        'Content-Type': 'application/json',
      },
      timeout: 6000,
    }, (res) => {
      let body = '';
      res.on('data', (d) => { body += d; });
      res.on('end', () => {
        if (res.statusCode !== 200) return resolve(null);
        try { resolve(JSON.parse(body)); } catch (e) { resolve(null); }
      });
    });
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.on('error', () => resolve(null));
  });
}

function pct(limit) {
  if (!limit || limit.utilization == null) return null;
  return Math.round(limit.utilization);
}

function extractUsage(u) {
  if (!u) return null;
  const scoped = [];
  for (const l of u.limits || []) {
    const name = l && l.scope && l.scope.model && l.scope.model.display_name;
    if (l && l.kind === 'weekly_scoped' && name && l.percent != null) {
      scoped.push({ name, percent: Math.round(l.percent) });
    }
  }
  return { session: pct(u.five_hour), week: pct(u.seven_day), scoped };
}

async function accountInfo(profile) {
  const cfg = readJson(profile.cfg) || {};
  const email = (cfg.oauthAccount || {}).emailAddress || null;
  const cred = await readCred(profile);
  const loggedIn = !!(cred && cred.accessToken);
  let loginDays = null;
  if (cred && typeof cred.refreshTokenExpiresAt === 'number') {
    loginDays = (cred.refreshTokenExpiresAt / 1000 - Date.now() / 1000) / 86400;
  }
  let usage = null;
  if (loggedIn) {
    // live first; Claude Code's own snapshot in .claude.json as fallback
    usage = extractUsage(await fetchUsage(cred.accessToken));
    if (!usage || usage.session == null) {
      const cached = (cfg.cachedUsageUtilization || {}).utilization;
      usage = extractUsage(cached) || usage;
    }
  }
  return { name: profile.name, dir: profile.dir, email, loggedIn, loginDays, usage };
}

// The usage cache is one JSON file in globalStorage shared by every VS Code
// window: whichever window finds it expired refreshes it for all of them, so
// N windows produce the request volume of one.
function readUsageCache() {
  const c = readJson(usageCachePath);
  return c && typeof c.ts === 'number' && Array.isArray(c.infos) ? c : null;
}

async function getAllInfos(force) {
  const disk = readUsageCache();
  if (!force && disk && Date.now() - disk.ts < USAGE_TTL_MS) return disk.infos;
  if (pendingRefresh) return pendingRefresh;
  pendingRefresh = Promise.all(profiles().map(accountInfo)).then((infos) => {
    try { fs.writeFileSync(usageCachePath, JSON.stringify({ ts: Date.now(), infos }, null, 2)); } catch (e) { log(`cache write failed: ${e}`); }
    pendingRefresh = null;
    return infos;
  }).catch((e) => {
    log(`refresh failed: ${e}`);
    pendingRefresh = null;
    return (readUsageCache() || {}).infos || [];
  });
  return pendingRefresh;
}

// ── map (folder -> profile) ────────────────────────────────────────

function readMap() { return readJson(mapPath) || {}; }

function writeMap(m) {
  fs.writeFileSync(mapPath, JSON.stringify(m, null, 2) + '\n');
}

function currentFolder() {
  const ws = vscode.workspace.workspaceFolders;
  return ws && ws.length ? ws[0].uri.fsPath : null;
}

function mappedProfileIn(m, folder) {
  if (!folder) return null;
  const cwd = canonical(folder);
  let best = '';
  let name = null;
  for (const [k, v] of Object.entries(m)) {
    const key = canonical(String(k));
    if ((cwd === key || cwd.startsWith(key + path.sep)) && key.length > best.length) {
      best = key; name = String(v);
    }
  }
  return name;
}

function mappedProfile(folder) { return mappedProfileIn(readMap(), folder); }

// ── status bar ─────────────────────────────────────────────────────

function fmtUsage(info) {
  if (!info.loggedIn) return 'logged out';
  if (!info.usage || info.usage.session == null) return 'usage n/a';
  let s = `S ${info.usage.session}% · W ${info.usage.week != null ? info.usage.week : '?'}%`;
  for (const sc of (info.usage.scoped || [])) s += ` · ${sc.name.toUpperCase()} ${sc.percent}%`;
  return s;
}

function fmtLogin(info) {
  if (!info.loggedIn) return '✗ logged out';
  const d = info.loginDays;
  if (d == null) return '✓ ok';
  if (d <= 0) return '✗ login expired';
  if (d <= 3) return `⚠ login expires in ${Math.ceil(d)}d`;
  return `✓ ${Math.floor(d)}d`;
}

function maxUsage(info) {
  if (!info.usage) return 0;
  const vals = [info.usage.session || 0, info.usage.week || 0, ...(info.usage.scoped || []).map((s) => s.percent || 0)];
  return Math.max(...vals, 0);
}

async function updateStatus() {
  const name = mappedProfile(currentFolder()) || 'default';
  statusItem.text = `$(account) Claude: ${name}`;
  statusItem.show();
  const infos = await getAllInfos(false);
  const info = infos.find((i) => i.name === name);
  if (!info) return;
  if (info.usage && info.usage.session != null) {
    statusItem.text = `$(account) Claude: ${name} ${info.usage.session}%`;
  }
  statusItem.backgroundColor = undefined;
  if (!info.loggedIn || (info.loginDays != null && info.loginDays <= 0)) {
    statusItem.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
  } else if (maxUsage(info) >= 80 || (info.loginDays != null && info.loginDays <= 3)) {
    statusItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
  }
  const md = new vscode.MarkdownString();
  md.appendMarkdown('**Claude accounts** (click to switch this window)\n\n');
  md.appendMarkdown('| | account | usage | login |\n|---|---|---|---|\n');
  for (const i of infos) {
    const active = i.name === name ? '✓' : '';
    md.appendMarkdown(`| ${active} | **${i.name}** ${i.email || ''} | ${fmtUsage(i)} | ${fmtLogin(i)} |\n`);
  }
  statusItem.tooltip = md;
}

// ── commands ───────────────────────────────────────────────────────

async function pickAccount() {
  const folder = currentFolder();
  if (!folder) {
    vscode.window.showWarningMessage('Claude Switch: open a folder first; account mapping is per project folder.');
    return;
  }
  const infos = await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Window, title: 'Claude Switch: reading accounts' },
    () => getAllInfos(true)
  );
  const active = mappedProfile(folder) || 'default';
  const items = infos.map((i) => ({
    label: `${i.name === active ? '$(check) ' : '$(circle-large-outline) '}${i.name}`,
    description: i.email || '',
    detail: `${fmtUsage(i)}   ${fmtLogin(i)}`,
    profile: i.name,
  }));
  items.push({ label: '', kind: vscode.QuickPickItemKind.Separator });
  items.push({ label: '$(discard) Use default account', description: 'default account for this folder, even if a parent folder is mapped', action: 'unmap' });
  items.push({ label: '$(add) Add a new account…', description: 'create a profile, then /login in the Claude panel', action: 'add' });
  const picked = await vscode.window.showQuickPick(items, {
    title: `Claude account for ${path.basename(folder)}`,
    placeHolder: `current: ${active}`,
  });
  if (!picked) return;
  if (picked.action === 'add') return addAccount(folder);
  const m = readMap();
  const key = canonical(folder);
  const chosen = picked.action === 'unmap' ? 'default' : picked.profile;
  if (chosen === 'default') {
    // Deleting this folder's entry only makes it inherit whatever a parent
    // folder is mapped to. When a parent would win, keep an explicit
    // "default" entry so longest-match picks it; the wrapper treats
    // "default" as "no CLAUDE_CONFIG_DIR", i.e. the default account.
    delete m[key];
    const inherited = mappedProfileIn(m, folder);
    if (inherited && inherited !== 'default') m[key] = 'default';
  } else {
    m[key] = chosen;
  }
  writeMap(m);
  await updateStatus();
  if (chosen !== active) {
    // reload immediately so the Claude panel comes back as the new account
    vscode.commands.executeCommand('workbench.action.reloadWindow');
  }
}

async function addAccount(folder) {
  const name = await vscode.window.showInputBox({
    title: 'New Claude account profile name',
    prompt: 'letters, numbers, - and _ only (e.g. mohan)',
    validateInput: (v) => {
      if (!/^[A-Za-z0-9_-]+$/.test(v)) return 'letters, numbers, - and _ only';
      if (EXCLUDE.has(v)) return 'that name is reserved';
      if (fs.existsSync(path.join(os.homedir(), `.claude-${v}`))) return 'profile already exists';
      return null;
    },
  });
  if (!name) return;
  const home = os.homedir();
  const dir = path.join(home, `.claude-${name}`);
  fs.mkdirSync(dir, { recursive: true });
  for (const f of SHARED_FILES) {
    try { fs.symlinkSync(path.join(home, '.claude', f), path.join(dir, f)); } catch (e) { /* exists */ }
  }
  const m = readMap();
  m[canonical(folder)] = name;
  writeMap(m);
  await updateStatus();
  // reload now; the Claude panel itself shows its sign-in flow for the new
  // (still credential-less) profile, so /login guidance is inherent
  vscode.commands.executeCommand('workbench.action.reloadWindow');
}

async function uninstall() {
  const cfg = vscode.workspace.getConfiguration('claudeCode');
  const insp = cfg.inspect('claudeProcessWrapper');
  if (insp && insp.globalValue === wrapperPath) {
    await cfg.update('claudeProcessWrapper', undefined, vscode.ConfigurationTarget.Global);
  }
  for (const f of [wrapperPath, mapPath, usageCachePath, path.join(path.dirname(mapPath), 'last-spawn.log')]) {
    try { fs.unlinkSync(f); } catch (e) { /* ignore */ }
  }
  statusItem.hide();
  vscode.window.showInformationMessage('Claude Switch: wrapper and mapping removed. Profiles and logins are untouched. You can now disable the extension.');
}

// ── bootstrap ──────────────────────────────────────────────────────

async function bootstrap(context) {
  const storageDir = context.globalStorageUri.fsPath;
  fs.mkdirSync(storageDir, { recursive: true });
  wrapperPath = path.join(storageDir, 'wrapper.sh');
  mapPath = path.join(storageDir, 'map.json');
  usageCachePath = path.join(storageDir, 'usage-cache.json');

  const template = fs.readFileSync(path.join(context.extensionPath, 'wrapper.template.sh'), 'utf8');
  const wanted = template.replace('__MAP_PATH__', mapPath);
  let current = null;
  try { current = fs.readFileSync(wrapperPath, 'utf8'); } catch (e) { /* missing */ }
  if (current !== wanted) {
    fs.writeFileSync(wrapperPath, wanted, { mode: 0o755 });
    fs.chmodSync(wrapperPath, 0o755);
    log(`wrapper written: ${wrapperPath}`);
  }
  if (!fs.existsSync(mapPath)) writeMap({});

  const cfg = vscode.workspace.getConfiguration('claudeCode');
  const insp = cfg.inspect('claudeProcessWrapper');
  const cur = insp && insp.globalValue;
  if (cur === undefined || cur === null || cur === '') {
    await cfg.update('claudeProcessWrapper', wrapperPath, vscode.ConfigurationTarget.Global);
    log('claudeCode.claudeProcessWrapper set');
  } else if (cur !== wrapperPath) {
    const c = await vscode.window.showWarningMessage(
      `Claude Switch: claudeCode.claudeProcessWrapper already points elsewhere (${cur}). Replace it with the Claude Switch wrapper?`,
      'Replace', 'Leave it');
    if (c === 'Replace') await cfg.update('claudeProcessWrapper', wrapperPath, vscode.ConfigurationTarget.Global);
  }
}

// ── activation ─────────────────────────────────────────────────────

async function activate(context) {
  output = vscode.window.createOutputChannel('Claude Switch');
  try {
    await bootstrap(context);
  } catch (e) {
    log(`bootstrap failed: ${e}`);
    vscode.window.showErrorMessage(`Claude Switch bootstrap failed: ${e.message || e}`);
    return;
  }
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 90);
  statusItem.command = 'claudeSwitch.pick';
  context.subscriptions.push(statusItem, output);
  context.subscriptions.push(vscode.commands.registerCommand('claudeSwitch.pick', pickAccount));
  context.subscriptions.push(vscode.commands.registerCommand('claudeSwitch.refresh', async () => {
    await getAllInfos(true); await updateStatus();
  }));
  context.subscriptions.push(vscode.commands.registerCommand('claudeSwitch.uninstall', uninstall));
  context.subscriptions.push(vscode.window.onDidChangeWindowState((s) => { if (s.focused) updateStatus(); }));
  const timer = setInterval(updateStatus, USAGE_TTL_MS);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
  updateStatus();
}

function deactivate() { }

module.exports = { activate, deactivate };
