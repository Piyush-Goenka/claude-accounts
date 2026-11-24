// VS Code extension: how setup-token profiles are shown. Runs under
// `node --test`, with a stub for the vscode module and a temporary HOME.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const Module = require('module');

const repo = path.resolve(__dirname, '..');
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'ca-ext-'));
process.env.HOME = home;
process.env.PATH = `${path.join(repo, 'tests', 'bin')}:${process.env.PATH}`;
delete process.env.CLAUDE_CODE_OAUTH_TOKEN;
delete process.env.CLAUDE_CONFIG_DIR;

const load = Module._load;
Module._load = function (request, ...rest) {
  if (request === 'vscode') return {}; // only activate() and the commands touch it
  return load.call(this, request, ...rest);
};
const ext = require(path.join(repo, 'vscode-claude-switch', 'extension.js'));
const { accountInfo, fmtLogin, fmtUsage } = ext._internals;

test.after(() => fs.rmSync(home, { recursive: true, force: true }));

function profile(name) {
  const dir = path.join(home, `.claude-${name}`);
  return { name, dir, cfg: path.join(dir, '.claude.json') };
}
function tokenProfile(name, token, label) {
  const p = profile(name);
  fs.mkdirSync(p.dir, { recursive: true });
  fs.writeFileSync(path.join(p.dir, '.setup-token'), token ? `${token}\n` : '', { mode: 0o600 });
  if (label !== undefined) {
    fs.writeFileSync(path.join(p.dir, '.claude-accounts.json'), JSON.stringify({ label }), { mode: 0o600 });
  }
  return p;
}
function cache(name, doc) {
  const dir = path.join(home, '.cache', 'claude-accounts');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, `ping-${name}.json`), JSON.stringify({ ts: Math.floor(Date.now() / 1000), ...doc }));
}
const win = (utilization, inSeconds) => ({ utilization, resets_at: new Date(Date.now() + inSeconds * 1000).toISOString() });

test('token profile with a fresh cache: label, usage, never the Keychain', async () => {
  const p = tokenProfile('fresh', 'tok-secret', 'work max');
  cache('fresh', { http: 200, five_hour: win(5, 7200), seven_day: win(20, 6 * 86400) });
  const info = await accountInfo(p);
  assert.equal(info.auth, 'token');
  assert.equal(info.tokenState, 'ok');
  assert.equal(info.loggedIn, true);
  assert.equal(info.email, 'work max');
  assert.equal(info.usage.session, 5);
  assert.equal(info.usage.week, 20);
  assert.equal(fmtLogin(info), '✓ token');
  assert.match(fmtUsage(info), /^S 5% · W 20% · as of \d\d:\d\d$/);
  assert.equal(fs.existsSync(path.join(home, '.calls', 'security.log')), false);
});

test('a window past its reset is dropped', async () => {
  const p = tokenProfile('reset', 'tok');
  cache('reset', { http: 200, five_hour: win(5, -3600), seven_day: win(20, 6 * 86400) });
  const info = await accountInfo(p);
  assert.equal(info.usage.session, null);
  assert.match(fmtUsage(info), /^S \?% · W 20% · as of /);
});

test('a rejected token', async () => {
  const p = tokenProfile('rejected', 'tok');
  cache('rejected', { http: 401 });
  const info = await accountInfo(p);
  assert.equal(info.tokenState, 'rejected');
  assert.equal(info.loggedIn, false);
  assert.equal(fmtLogin(info), '✗ token rejected');
});

test('an empty token file', async () => {
  const info = await accountInfo(tokenProfile('empty', ''));
  assert.equal(info.tokenState, 'missing');
  assert.equal(fmtLogin(info), '✗ no token');
});

test('the token file is never read: state comes from its size', async () => {
  const p = tokenProfile('locked', 'tok-secret');
  fs.chmodSync(path.join(p.dir, '.setup-token'), 0o000);
  assert.equal((await accountInfo(p)).tokenState, 'ok');
});

test('no cache means no usage', async () => {
  const info = await accountInfo(tokenProfile('nocache', 'tok'));
  assert.equal(info.usage, null);
  assert.equal(fmtUsage(info), 'usage n/a');
});

test('browser-login strings are unchanged', () => {
  assert.equal(fmtLogin({ loggedIn: true, loginDays: 28.4 }), '✓ 28d');
  assert.equal(fmtUsage({ loggedIn: true, usage: { session: 11, week: 1, scoped: [{ name: 'Fable', percent: 0 }] } }),
    'S 11% · W 1% · FABLE 0%');
});

test('the extension carries the same version as the tool', () => {
  const tool = fs.readFileSync(path.join(repo, 'claude-accounts.zsh'), 'utf8')
    .match(/^CLAUDE_ACCOUNTS_VERSION="([^"]+)"/m)[1];
  assert.equal(require(path.join(repo, 'vscode-claude-switch', 'package.json')).version, tool);
});
