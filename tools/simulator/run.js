// Boot BaseOS outside Minecraft, under a real Lua 5.4 VM (wasmoon) with a
// mocked ComputerCraft: Tweaked API.
//
//   cd tools/simulator && npm install
//   node run.js                      # default scenario
//   node run.js scenarios/resilience.lua
//   MAX_EVENTS=200 node run.js
//
// This is a development aid only: nothing here ships to the computer in game.

const { LuaFactory } = require('wasmoon');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SCENARIO = process.argv[2] || 'scenarios/dashboard.lua';

/** Collect every .lua file in the project, keyed by CC-style relative path. */
function collect(dir, base, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === '.git' || entry.name === 'node_modules') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) collect(full, base, out);
    else if (entry.name.endsWith('.lua') || entry.name === 'baseos.version') {
      out[path.relative(base, full).split(path.sep).join('/')] = fs.readFileSync(full, 'utf8');
    }
  }
  return out;
}

/** Escape a JS string into a Lua double-quoted literal. */
function luaString(value) {
  const escapes = { '\\': '\\\\', '"': '\\"', '\r': '\\r', '\n': '\\n', '\t': '\\t' };
  return (
    '"' +
    value
      .replace(/[\\"\r\n\t]/g, (c) => escapes[c])
      .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, (c) => '\\' + c.charCodeAt(0)) +
    '"'
  );
}

(async () => {
  const factory = new LuaFactory();
  const lua = await factory.createEngine({ openStandardLibs: true });

  const files = collect(ROOT, ROOT, {});
  console.log(`[simulator] ${Object.keys(files).length} lua files, scenario ${SCENARIO}`);

  // wasmoon exposes JS objects as proxies that Lua's `pairs` cannot walk, so
  // the file map is handed over as generated Lua source.
  const fileMap =
    '__FILES = {\n' +
    Object.entries(files)
      .map(([name, contents]) => `  [${luaString(name)}] = ${luaString(contents)},`)
      .join('\n') +
    `\n}\n__MAX_EVENTS = ${process.env.MAX_EVENTS || 400}\n` +
    `__MONITOR_W = ${process.env.MONITOR_W || 82}\n` +
    `__MONITOR_H = ${process.env.MONITOR_H || 25}\n`;

  try {
    await lua.doString(fileMap);
    await lua.doString(fs.readFileSync(path.join(__dirname, 'mock_cc.lua'), 'utf8'));
    await lua.doString(fs.readFileSync(path.join(__dirname, SCENARIO), 'utf8'));
  } catch (err) {
    console.error('[simulator] FAILED:', err.message);
    process.exitCode = 1;
  } finally {
    lua.global.close();
  }
})();
