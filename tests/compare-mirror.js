// Verifies that every mirrored session index equals its original, except account-bound fields.
// usage: node compare-mirror.js <sessionsRoot>
const fs = require('fs'), path = require('path');
const BOUND = new Set(['remoteMcpServersConfig', 'enabledMcpTools', 'bridgeSessionIds', 'remoteControlUserEnabled',
  'remoteControlAutoEligible', 'steeredByRemoteClient', 'chromeTabGroupId', 'startedFromEnvironmentId',
  // scheduledTaskId was account-bound in v1 and is kept since v2; old mirrors may still lack it
  'scheduledTaskId']);
const root = process.argv[2];
const byName = {};
for (const acct of fs.readdirSync(root)) {
  const ad = path.join(root, acct);
  if (!fs.statSync(ad).isDirectory()) continue;
  for (const org of fs.readdirSync(ad)) {
    const od = path.join(ad, org);
    if (!fs.statSync(od).isDirectory()) continue;
    for (const f of fs.readdirSync(od)) if (/^local_.*\.json$/.test(f)) {
      const p = path.join(od, f);
      (byName[f] ||= []).push({ acct, p, mtime: fs.statSync(p).mtimeMs, j: JSON.parse(fs.readFileSync(p, 'utf8')) });
    }
  }
}
const strip = o => JSON.stringify(Object.fromEntries(Object.entries(o).filter(([k]) => !BOUND.has(k)).sort(([a], [b]) => a < b ? -1 : 1)));
let pairs = 0, bad = 0;
for (const [f, copies] of Object.entries(byName)) {
  if (copies.length < 2) continue;
  pairs++;
  const [a, b] = copies;
  if (strip(a.j) !== strip(b.j)) {
    bad++;
    const keys = new Set([...Object.keys(a.j), ...Object.keys(b.j)]);
    const diff = [...keys].filter(k => !BOUND.has(k) && JSON.stringify(a.j[k]) !== JSON.stringify(b.j[k]));
    console.log('DIFF', f, diff.join(','));
  }
}
console.log(`pairs=${pairs} different=${bad}`);
process.exit(bad ? 1 : 0);
