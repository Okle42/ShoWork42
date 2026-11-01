// 介面層的小工具（11-02 P8）：h() 建 DOM（取代 SwiftUI 的 View 組法）、SF Symbols 的替身圖示（內嵌 SVG，離線可用）。
// 只建 DOM，不管狀態；狀態在 office.js（OfficeView 的 @State）。

/** h("div.cls#id", {attrs, on:{click}}, ...children)：children 可以是字串、節點、陣列、null（略過） */
export function h(sel, attrs, ...kids) {
  if (attrs === null || typeof attrs !== "object" || attrs instanceof Node || Array.isArray(attrs)) { kids.unshift(attrs); attrs = {}; }
  const m = /^([a-z0-9]+)?((?:[.#][\w-]+)*)$/i.exec(sel) ?? [];
  const el = document.createElement(m[1] || "div");
  for (const part of (m[2] ?? "").match(/[.#][\w-]+/g) ?? []) {
    if (part[0] === ".") el.classList.add(part.slice(1)); else el.id = part.slice(1);
  }
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "on") { for (const [ev, f] of Object.entries(v)) el.addEventListener(ev, f); continue; }
    if (k === "style" && typeof v === "object") { for (const [sk, sv] of Object.entries(v)) { if (sk.startsWith("--")) el.style.setProperty(sk, sv); else el.style[sk] = sv; } continue; }
    if (k === "class") { for (const c of String(v).split(/\s+/).filter(Boolean)) el.classList.add(c); continue; }
    if (k === "title") { el.title = v; continue; }
    if (k === "html") { el.innerHTML = v; continue; }
    if (k in el && typeof v !== "string") { el[k] = v; continue; }
    el.setAttribute(k, v === true ? "" : v);
  }
  add(el, kids);
  return el;
}
function add(el, kids) {
  for (const k of kids) {
    if (k === null || k === undefined || k === false) continue;
    if (Array.isArray(k)) add(el, k);
    else el.append(k instanceof Node ? k : document.createTextNode(String(k)));
  }
}

/** 換掉一個容器的內容（保留捲動位置） */
export function replace(el, ...kids) {
  const st = el.scrollTop;
  el.replaceChildren();
  add(el, kids);
  el.scrollTop = st;
}

// MARK: - 圖示（SF Symbols 的替身：線條 1.6、圓角，跟系統圖示同樣的視覺重量）

const P = {
  "circle.lefthalf.filled": '<circle cx="12" cy="12" r="8.2" fill="none"/><path d="M12 3.8a8.2 8.2 0 0 0 0 16.4z" fill="currentColor" stroke="none"/>',
  "moon.stars": '<path d="M14.5 4.2a7.6 7.6 0 1 0 5.3 11.4A6.2 6.2 0 0 1 14.5 4.2z" fill="none"/><path d="M18 3.5v3M16.5 5h3" />',
  "sun.max": '<circle cx="12" cy="12" r="3.8" fill="none"/><path d="M12 2.5v2.4M12 19.1v2.4M2.5 12h2.4M19.1 12h2.4M5.3 5.3l1.7 1.7M17 17l1.7 1.7M5.3 18.7 7 17M17 7l1.7-1.7"/>',
  "cloud.sun": '<path d="M9 7.2a3.2 3.2 0 0 1 5.6 1.4M9 3v1.4M4.6 4.6l1 1M3 9h1.4"/><path d="M7.5 19.5h9a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6 1.4 2.8 2.8 0 0 0 .3 5.6z" fill="none"/>',
  "cloud": '<path d="M7 19h10.5a4 4 0 0 0 .4-8A5.6 5.6 0 0 0 7.1 12a3.5 3.5 0 0 0-.1 7z" fill="none"/>',
  "cloud.drizzle": '<path d="M7 15h10.5a4 4 0 0 0 .4-8A5.6 5.6 0 0 0 7.1 8a3.5 3.5 0 0 0-.1 7z" fill="none"/><path d="M9 18l-.6 1.6M13 18l-.6 1.6M17 18l-.6 1.6"/>',
  "cloud.heavyrain": '<path d="M7 14h10.5a4 4 0 0 0 .4-8A5.6 5.6 0 0 0 7.1 7a3.5 3.5 0 0 0-.1 7z" fill="none"/><path d="M8.5 16.5l-1.2 4M12.5 16.5l-1.2 4M16.5 16.5l-1.2 4"/>',
  "cloud.bolt.rain": '<path d="M7 14h10.5a4 4 0 0 0 .4-8A5.6 5.6 0 0 0 7.1 7a3.5 3.5 0 0 0-.1 7z" fill="none"/><path d="M12.5 15l-2 3h3l-2 3M7.5 17l-.8 2M17 17l-.8 2"/>',
  "wind": '<path d="M3 9h11a2.5 2.5 0 1 0-2.5-2.5M3 13h15a2.5 2.5 0 1 1-2.5 2.5M3 17h8"/>',
  "cloud.slash": '<path d="M7 19h10.5a4 4 0 0 0 .4-8A5.6 5.6 0 0 0 7.1 12a3.5 3.5 0 0 0-.1 7z" fill="none"/><path d="M4 4l16 16"/>',
  "hourglass": '<path d="M7 3.5h10M7 20.5h10M8 3.5c0 4.5 8 5 8 8.5s-8 4-8 8.5M16 3.5c0 4.5-8 5-8 8.5s8 4 8 8.5" fill="none"/>',
  "paintbrush": '<path d="M14.5 4.5l5 5-7.2 7.2-5-5z" fill="none"/><path d="M7.3 11.7l-1.6 1.6a2.6 2.6 0 0 0 0 3.7l.2.2M7 18c-1 1.8-2.6 2.4-4 2.5.7-1.4 1-2.7.8-4"/>',
  "scope": '<circle cx="12" cy="12" r="7" fill="none"/><circle cx="12" cy="12" r="2" fill="none"/><path d="M12 2.5v4M12 17.5v4M2.5 12h4M17.5 12h4"/>',
  "questionmark.circle": '<circle cx="12" cy="12" r="8.5" fill="none"/><path d="M9.6 9.5a2.5 2.5 0 1 1 3.4 2.3c-.7.3-1 .8-1 1.6v.4"/><circle cx="12" cy="16.6" r=".6" fill="currentColor"/>',
  "chevron.down": '<path d="M7 10l5 5 5-5" fill="none"/>',
  "chevron.right": '<path d="M10 7l5 5-5 5" fill="none"/>',
  "chevron.backward": '<path d="M14 7l-5 5 5 5" fill="none"/>',
  "xmark.circle.fill": '<circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="M9 9l6 6M15 9l-6 6" stroke="var(--xmark-ink, #2a2a2c)" stroke-width="1.9"/>',
  "checkmark.circle": '<circle cx="12" cy="12" r="8.5" fill="none"/><path d="M8.2 12.3l2.5 2.5 5-5.4" fill="none"/>',
  "checkmark.shield": '<path d="M12 3l7 2.8v5.4c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V5.8z" fill="none"/><path d="M8.8 12l2.3 2.3 4.2-4.6" fill="none"/>',
  "shield.lefthalf.filled": '<path d="M12 3l7 2.8v5.4c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V5.8z" fill="none"/><path d="M12 3L5 5.8v5.4c0 4.3 3 7.6 7 9z" fill="currentColor" stroke="none"/>',
  "building.2": '<path d="M4 20.5V7.5l6-3v16M10 20.5V9.5l7 2.5v8.5M2.5 20.5h19M6.5 9.5v.01M6.5 13v.01M6.5 16.5v.01M13 14v.01M13 17v.01" fill="none"/>',
  "tray.full": '<path d="M3.5 13.5l2.2-7.5h12.6l2.2 7.5v5h-17z" fill="none"/><path d="M3.5 13.5h5l1 2h5l1-2h5M8 8.8h8M7.4 11h9.2" fill="none"/>',
  "person.crop.circle": '<circle cx="12" cy="12" r="9" fill="none"/><circle cx="12" cy="10" r="3" fill="none"/><path d="M6.4 18.6c1.3-2.2 3.3-3.3 5.6-3.3s4.3 1.1 5.6 3.3" fill="none"/>',
  "person.crop.circle.badge.checkmark": '<circle cx="11" cy="12" r="8.4" fill="none"/><circle cx="11" cy="10.2" r="2.8" fill="none"/><path d="M5.8 18.2c1.2-2 3-3.1 5.2-3.1s4 1.1 5.2 3.1M16.8 5.2l1.6 1.6 3-3.2" fill="none"/>',
  "terminal": '<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="none"/><path d="M7 9.5l3 2.5-3 2.5M12 15h5" fill="none"/>',
  "list.bullet.rectangle": '<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="none"/><path d="M10 9.5h7M10 12h7M10 14.5h7M7 9.5v.01M7 12v.01M7 14.5v.01"/>',
  "list.bullet.rectangle.fill": '<rect x="3" y="4.5" width="18" height="15" rx="2.5" fill="currentColor"/><path d="M10 9.5h7M10 12h7M10 14.5h7M7 9.5v.01M7 12v.01M7 14.5v.01" stroke="var(--xmark-ink, #2a2a2c)"/>',
  "text.bubble": '<path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4A2.5 2.5 0 0 1 4 13.5z" fill="none"/><path d="M8 8.5h8M8 11.5h5"/>',
  "text.bubble.fill": '<path d="M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 4v-4A2.5 2.5 0 0 1 4 13.5z" fill="currentColor"/><path d="M8 8.5h8M8 11.5h5" stroke="var(--xmark-ink, #2a2a2c)"/>',
  "wrench.and.screwdriver": '<path d="M14.5 6.5a3.5 3.5 0 0 0 4.4 4.4L20 12l-8 8-2-2 8-8M4 4l3 1 5 5-2 2-5-5z" fill="none"/>',
  "doc.text": '<path d="M7 3.5h7l4 4v13H7z" fill="none"/><path d="M9.5 11h6M9.5 14h6M9.5 17h4"/>',
  "paperplane": '<path d="M3.5 11.5l17-7.5-6 17-3-7z" fill="none"/><path d="M11.5 14l9-10"/>',
  "arrow.clockwise": '<path d="M18.5 12a6.5 6.5 0 1 1-2-4.7M18.5 4.5v3.5H15" fill="none"/>',
  "star": '<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 17l-5.2 2.7 1-5.9-4.3-4.1 5.9-.8z" fill="none"/>',
  "star.fill": '<path d="M12 3.5l2.6 5.4 5.9.8-4.3 4.1 1 5.9L12 17l-5.2 2.7 1-5.9-4.3-4.1 5.9-.8z" fill="currentColor"/>',
  "minus.circle": '<circle cx="12" cy="12" r="8.5" fill="none"/><path d="M8 12h8"/>',
  "plus.circle": '<circle cx="12" cy="12" r="8.5" fill="none"/><path d="M8 12h8M12 8v8"/>',
  "checkmark": '<path d="M6 12.5l4 4 8-9" fill="none"/>',
  "circle": '<circle cx="12" cy="12" r="8" fill="none"/>',
  "checkmark.circle.fill": '<circle cx="12" cy="12" r="8.5" fill="currentColor" stroke="none"/><path d="M8.2 12.3l2.5 2.5 5-5.4" fill="none" stroke="var(--xmark-ink, #2a2a2c)"/>',
};

/** 一個圖示（SF Symbol 名稱）；size＝點 */
export function Icon(name, size = 15, extra = "") {
  const s = document.createElement("span");
  s.className = "sym" + (extra ? " " + extra : "");
  s.innerHTML = `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[name] ?? P.circle}</svg>`;
  return s;
}
