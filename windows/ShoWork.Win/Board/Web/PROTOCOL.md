# 3D 辦公大樓網頁 ⇄ C# 的訊息格式（11-02 P8）

網頁：`office.html`＋`office.js`（照搬 Mac `OfficeView.swift`）。C# 端：`Board\View\OfficeHost.cs`（WebView2）。
- C# → 網頁：`CoreWebView2.PostWebMessageAsJson(json)`。
- 網頁 → C#：`chrome.webview.postMessage(obj)`，C# 在 `WebMessageReceived` 讀 `WebMessageAsJson`。
- 時間一律是 Unix 秒（Swift `Date` 的 Mirror 編碼）。
- 示範模式（`office.html?demo=1`）不送任何動作，只在畫面下方顯示「示範資料：不送出」。

## C# → 網頁

### `office2`：整份資料（必要）
形狀同 `bench/mac-input.json`，見 `Board\Core\Office2.cs`。網頁用到的欄位如下。

| 欄位 | 用途 |
|---|---|
| `tower` `decor` `wander` `islands` `guardStatus` `scanning` | 場景（OfficeBuilder.update）、樓層索引列、需要你列 |
| `city` | 城市（可為 null，等於 `SHOWORK_CITY=off`）、設備警示、城市細節卡 |
| `site` | 主天氣地點 `{title, lat, lon, detail?}`，給日出日落（燈光「自動」）用 |
| `weather` | `{ now: {code, rainRate, cloudCover, wind, gust}, look, at? }` 或 null。網頁自己用 `now` 算 WeatherLook |
| `lighting` | 只在網頁還沒存過燈光設定時當初值用（`day`／`night`／`auto`） |
| `graph` | B1 神經網路；`nodes` 是空的就留著示範圖譜（Mac：`NeuralGraph.demo()`） |
| `colors` | 狀態色 `{working, input, done}: "#RRGGBB"`（終端機發光設定，名牌字色跟著變） |
| `now` | 資料的時間點（閒晃行程用） |

`look`、`night`、`reduceMotion` 網頁目前不讀：天色由網頁自己用 `scene/solar.js` 算。這樣在畫面上切換燈光，不用等 C# 下一輪就會變。

以下是網頁另外會讀的欄位（**選填**，沒有就用預設值）。

| 欄位 | 形狀 | 沒給時 |
|---|---|---|
| `cards` | `BoardCard[]`（Mac 形狀，含排隊卡 `#q…`） | 從 `islands[].people[].card` 取 |
| `captainThread` | `CaptainLine[]`：`{id, at, role: "kang"\|"captain"\|"report"\|"tool", text, via?}` | 空 |
| `captainTasks` | `CaptainTask[]`：`{id, to, toSession?, project?, text, state: "sent"\|"working"\|"review"\|"done"\|"blocked"\|"cancelled"}`（只放還沒結的） | 空 |
| `sessionThread` | 右側對話窗格那個 AI 的對話（`watch` 指定的那個），格式同 `captainThread` | 空 |
| `runs` | `RunProgress[]`：`{name?, label, done?, total?, eta?, updatedAt, fraction}` | 空 |
| `reviewing` | 正在 AI 審核的 sessionId 陣列（右鍵「重新審核」要不要反灰） | 空 |
| `captainBusy` | 隊長正在開（askCaptain 跑的時候） | false |
| `captainModelTitle` | 「不在：送出時開 ___ 隊長」 | `"Opus 5.5"` |
| `b1Posts` | B1 交流互動板 `[{id, at, name, project, text, re?}]`（舊的在前） | 空 |
| `weatherSites` | `[{ site, report: {now, at} \| null, failed }]`（天氣列每個地點） | 只有主地點 |
| `weatherMenuStatus` | 燈光選單裡那行天氣狀態 | 網頁自己組 |

### 其他訊息
| type | 欄位 | 網頁做什麼 |
|---|---|---|
| `heat` | `paused: bool` | HeatGate：機器熱 ⇒ 持續動畫全停，路上的人直接落地 |
| `visible` | `visible: bool` | 視窗被蓋住或縮小時（WebView2 的 visibilityState 抓不到的情況）⇒ 暫停整個場景 |
| `toast` | `text`, `captainDone?` | 顯示一行提示（BoardActions 回傳的那句話）；`captainDone` 會清掉「隊長開啟中」 |
| `captainBusy` | `busy` | 同上，只改狀態 |
| `b1Posts` | `posts` | 交流互動板內容（回應 `b1Refresh`） |
| `weatherResults` | `results: WeatherSite[]`, `note?` | 地點搜尋結果（回應 `weatherSearch`） |
| `dropPaths` | `key`, `paths: string[]` | 拖進輸入框的檔案路徑（回應 `dropFiles`） |
| `deselect` | | 關掉回答卡 |

## 網頁 → C#

### 生命週期
- `{type:"ready"}`：頁面好了，C# 可以開始推 `office2`（OfficeHost 已實作）。
- `{type:"dropFiles", key}`，用 `chrome.webview.postMessageWithAdditionalObjects(msg, files)` 送出：把拖進輸入框的 `File` 一起交給 C#。C# 從 `e.AdditionalObjects` 取 `CoreWebView2File.Path`，回 `{type:"dropPaths", key, paths}`。3 秒沒回，就只插檔名。

### 動作 `{type:"action", action, …}`
名稱照 Mac 的 `BoardActions`。`id` 是卡片 id，`sessionId` 是卡片的 sessionId。

| action | 欄位 | Mac 對應 | 從哪裡按 |
|---|---|---|---|
| `answer` | `id, sessionId, text` | `BoardActions.answer(card, text)` | 回答卡、收件匣選項／打字、右側對話窗格 |
| `permit` | `id, sessionId, permitId, decision: "allow"\|"always"\|"deny", message?, answers?` | `BoardActions.permit(card, PermitAnswer)`；`answers` 是 `{題目: [選的]}`（AskUserQuestion） | 收件匣：權限、選擇題、計畫確認 |
| `askCaptain` | `text` | `BoardActions.askCaptain(text)`（隊長不在就開一個）。做完回 `toast` 並帶 `captainDone:true` | 收件匣下方「交給隊長」 |
| `focus` | `id, sessionId, pid, kind` | `BoardActions.focus(pid:)`：跳到終端機視窗。找不到時回 toast：`kind == "bg"` 回「這是背景 session，沒有視窗；用 claude attach 打開」，其他回「找不到這個 session 的視窗」 | 回答卡、收件匣、右鍵「跳到這個視窗」、對話窗格終端機鈕 |
| `approve` | `id, sessionId` | `BoardActions.approve`（放行） | 右鍵「放行」（只有 review 欄） |
| `dispatch` | `id, sessionId` | `onDispatch(card)`：開「派工給它⋯」對話框（BoardWindow 的 sheet，C# 端要做） | 右鍵 |
| `sendBack` | `id, sessionId` | `onSendBack(card)`：開「退回並補指示⋯」對話框（同上） | 右鍵 |
| `park` | `id, sessionId` | `onPark(card)`：開「丟回待辦⋯」對話框（同上） | 右鍵 |
| `review` | `id, sessionId, force: true` | `Reviewer.shared.start(card, force: true)` | 右鍵「重新審核」 |
| `redecorate` | `project` | `BoardModel.redecorate(project)`，回 toast | 右上「重新裝潢」、右鍵 |
| `guardScan` | | `BoardModel.guardScan()`，回 toast「開始掃描 Wi-Fi（約數十秒）」或「已經在掃描了」 | 保全面板、保全右鍵 |
| `pushAllow` | `dir, head, repo` | `PushGuard.allow(event)` | 保全面板「放行一次」 |
| `watch` | `sessionId \| null` | `BoardModel.watch(sid)`：右側對話窗格改讀這個 AI 的對話（推到 `sessionThread`）；null＝隊長 | 點角色、對話窗格返回 |
| `openGraph` | `project` | `GraphSource.openBuilding(clicked:)`：用預設瀏覽器開整棟大樓的知識星雲，回 toast | 點 B1 神經網路 |
| `b1Refresh` | | 讀 `board/b1-board.jsonl`，回 `{type:"b1Posts"}` | 點 B1 留言板、重新整理 |
| `weatherSearch` | `query` | `OfficeWeather.search`（Open-Meteo 地名搜尋），回 `weatherResults` | 天氣地點面板 |
| `setPref` | `key, value` | 寫進設定（Mac：UserDefaults `ai.okle42.showork`）。`key` 可能是 `lighting`（day／night／auto）、`style`（voxel／diorama／blueprint）、`weather`（bool）、`weatherPlaces`（WeatherSite[]，第一個是主天氣）、`guardPatrol`（bool） | 右上選單、保全面板 |
| `wanderVisible` | `visible` | `BoardModel.wanderVisible`：看不到（或太熱、減少動態效果）時不排閒晃 | 視窗可見度變化時自動送 |

拷貝 Session ID 由網頁自己處理（`navigator.clipboard`），不送 C#。

網頁也把設定存在 `localStorage`（`office.*`），重開時先用這份。C# 收到 `setPref` 後要自己保存，因為 C# 也要靠這些設定算 `look` 和巡邏。
