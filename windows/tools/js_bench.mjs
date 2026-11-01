#!/usr/bin/env node
// JS 端 3D 量尺的驅動（11-01 P0）：開本機 http.server、headless Chrome（CDP，用 node 24 內建 WebSocket，不裝套件），
// 打開 Web/bench/bench.html 拍圖、讀 dump。
//
//   node windows/tools/js_bench.mjs --out <資料夾> [--shots default:0,top:1 | --all] [--kit] [--dump]
//     --shots   鏡頭:夜(0/1) 逗號分隔；--all ＝ 6 個鏡頭 × 日夜
//     --kit     地基小測試場景（日、夜各一張）
//     --dump    同時存 dump JSON（城市：js-scene-day/night.json，取 default 那份；kit：js-kit-day/night.json）
//   輸出：js-<day|night>-<cam>.png、js-kit-<day|night>.png（跟 Mac 的 day-default.png、mac-kit-day.png 對應）
//   環境變數 CHROME＝Chrome 執行檔（預設 macOS 的 Google Chrome）。

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
const CAMS = ["default", "overview", "top", "branch", "airship", "port"];
let shots = [];
if (has("--all")) for (const n of [0, 1]) for (const c of CAMS) shots.push([c, n]);
else if (opt("--shots")) shots = opt("--shots").split(",").map(s => { const [c, n] = s.split(":"); return [c, +(n ?? 0)]; });
const kit = has("--kit"), dump = has("--dump");
if (!shots.length && !kit) { console.error("要給 --shots、--all 或 --kit"); process.exit(2); }

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
for (let i = 0; i < 50; i++) { try { const r = await fetch(`http://127.0.0.1:${port}/bench/bench.html`); if (r.ok) break; } catch {} await sleep(100); }

async function open(query, png, dumpPath) {
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  const S = (m, p) => send(m, p, sessionId);
  await S("Emulation.setDeviceMetricsOverride", { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
  await S("Page.enable");
  await S("Runtime.enable");
  await S("Page.navigate", { url: `http://127.0.0.1:${port}/bench/bench.html?${query}` });
  const ev = async e => (await S("Runtime.evaluate", { expression: e, returnByValue: true })).result.value;
  let ok = false;
  for (let i = 0; i < 600; i++) { if (await ev("window.__ready === true")) { ok = true; break; } await sleep(100); }
  if (!ok) throw new Error("逾時：" + query);
  const err = await ev("window.__error ?? null");
  if (err) throw new Error(`${query}：${err}`);
  await sleep(200);
  const shot = await S("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: 1600, height: 1000, scale: 1 } });
  writeFileSync(png, Buffer.from(shot.data, "base64"));
  console.log("js shot", png, JSON.stringify(await ev("window.__info")));
  if (dumpPath) {
    const d = await ev("window.__dump ?? null");
    if (d) { writeFileSync(dumpPath, d); console.log("js dump", dumpPath, Math.round(d.length / 1024), "KB"); }
  }
  await send("Target.closeTarget", { targetId });
}

try {
  const dumped = new Set();
  for (const [c, n] of shots) {
    const tag = n ? "night" : "day";
    const wantDump = dump && !dumped.has(tag);
    if (wantDump) dumped.add(tag);
    await open(`cam=${c}&night=${n}${wantDump ? "&dump=1" : ""}`, join(out, `js-${tag}-${c}.png`), wantDump ? join(out, `js-scene-${tag}.json`) : null);
  }
  if (kit) for (const n of [0, 1]) {
    const tag = n ? "night" : "day";
    await open(`test=kit&night=${n}${dump ? "&dump=1" : ""}`, join(out, `js-kit-${tag}.png`), dump ? join(out, `js-kit-${tag}.json`) : null);
  }
} catch (e) {
  console.error(String(e.stack || e));
  process.exitCode = 1;
}
ws.close();
cleanup();
process.exit(process.exitCode ?? 0);
