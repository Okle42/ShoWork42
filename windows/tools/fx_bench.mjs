#!/usr/bin/env node
// B1／雨的 JS 量尺驅動（11-02 P8；跟 js_bench.mjs 同一套 CDP 做法，只是打開 Web/bench/fx.html）。對照 Mac `--office-bench rain`。
//
//   node windows/tools/fx_bench.mjs --out <資料夾> --name <檔名> --query "w=typhoon&cam=16,25,60&t=4[&target=x,y,z][&dump=1]"
//   輸出：<name>.png（有 dump=1 時另存 <name>.json）
//   Mac 對照：SHOWORK_BENCH_WEATHER=typhoon SHOWORK_BENCH_CAM=16,25,60 [SHOWORK_BENCH_TARGET=x,y,z] SHOWORK_BENCH_DIR=<資料夾>
//             .build/debug/ShoWorkAgent --office-bench rain <秒> 10   （每 2 秒存一張 rain_t<秒>_az<方位>.png）
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createServer } from "node:net";

const here = dirname(fileURLToPath(import.meta.url));
const WEB = resolve(here, "../ShoWork.Win/Board/Web");
const args = process.argv.slice(2);
const opt = k => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
const has = k => args.includes(k);
const out = resolve(opt("--out") ?? "bench-out");
mkdirSync(out, { recursive: true });
const query = opt("--query"), name = opt("--name") ?? "fx";
if (!query) { console.error("要給 --query"); process.exit(2); }

const sleep = ms => new Promise(r => setTimeout(r, ms));
const freePort = () => new Promise(r => { const s = createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });

const port = await freePort();
const http = spawn("python3", ["-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", WEB], { stdio: "ignore" });
const prof = mkdtempSync(join(tmpdir(), "jsbench-"));
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const chrome = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${prof}`, "--force-color-profile=srgb",
  "--hide-scrollbars", "--no-first-run", "--no-default-browser-check", "--window-size=1600,1000", "--ignore-gpu-blocklist", "about:blank"],
  { stdio: ["ignore", "ignore", "pipe"] });
let chromeErr = "";
chrome.stderr.on("data", d => { chromeErr += d; });
const cleanup = () => { try { chrome.kill(); } catch {} try { http.kill(); } catch {} try { rmSync(prof, { recursive: true, force: true }); } catch {} };
process.on("exit", cleanup);

// DevToolsActivePort：第一行 port、第二行 browser 的 ws 路徑
let wsUrl = null;
for (let i = 0; i < 100 && !wsUrl; i++) {
  const f = join(prof, "DevToolsActivePort");
  if (existsSync(f)) { const [p, path] = readFileSync(f, "utf8").trim().split("\n"); if (path) wsUrl = `ws://127.0.0.1:${p}${path}`; }
  if (!wsUrl) await sleep(100);
}
if (!wsUrl) { console.error("Chrome 沒起來", chromeErr.slice(0, 2000)); process.exit(1); }
const ws = new WebSocket(wsUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let id = 0;
const waiting = new Map();
ws.onmessage = ev => { const m = JSON.parse(ev.data); if (m.id && waiting.has(m.id)) { const [r, j] = waiting.get(m.id); waiting.delete(m.id); m.error ? j(new Error(JSON.stringify(m.error))) : r(m.result); } };
const send = (method, params = {}, sessionId) => new Promise((r, j) => { const i = ++id; waiting.set(i, [r, j]); ws.send(JSON.stringify({ id: i, method, params, sessionId })); });

// 確認 http.server 起來了
for (let i = 0; i < 50; i++) { try { const r = await fetch(`http://127.0.0.1:${port}/bench/fx.html`); if (r.ok) break; } catch {} await sleep(100); }

async function open(query, png, dumpPath) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const S = (m, p) => send(m, p, sessionId);
  await S("Emulation.setDeviceMetricsOverride", { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
  await S("Page.enable");
  await S("Runtime.enable");
  await S("Page.navigate", { url: `http://127.0.0.1:${port}/bench/fx.html?${query}` });
  const ev = async e => (await S("Runtime.evaluate", { expression: e, returnByValue: true })).result.value;
  let ok = false;
  for (let i = 0; i < 600; i++) { if (await ev("window.__ready === true")) { ok = true; break; } await sleep(100); }
  if (!ok) throw new Error("逾時：" + query);
  const err = await ev("window.__error ?? null");
  if (err) throw new Error(`${query}：${err}`);
  await sleep(200);
  const shot = await S("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: 1600, height: 1000, scale: 1 } });
  writeFileSync(png, Buffer.from(shot.data, "base64"));
  console.log("fx shot", png, JSON.stringify(await ev("window.__info")));
  if (dumpPath) {
    const d = await ev("window.__dump ?? null");
    if (d) { writeFileSync(dumpPath, d); console.log("js dump", dumpPath, Math.round(d.length / 1024), "KB"); }
  }
  await send("Target.closeTarget", { targetId });
}

try {
  await open(query, join(out, `${name}.png`), query.includes("dump=1") ? join(out, `${name}.json`) : null);
} catch (e) {
  console.error(String(e.stack || e));
  process.exitCode = 1;
}
ws.close();
cleanup();
process.exit(process.exitCode ?? 0);
