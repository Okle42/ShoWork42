# 流程檢討：小島村莊（11-12，分支 po46/island）

## 錯誤清單
1. 島民第一版沿用大樓 Kubo 原尺寸，全島視角下小到看不出誰是誰 → 多跑一輪截圖才放大 1.3 倍（約 5 分鐘）。根因：大樓一層 12 公尺寬，小島直徑 50 公尺，比例沒先算。
2. 廣場第一版 8 人一圈、半徑 2.4，放大後人疊在一起；第二圈半徑撞到樹（測試抓到）。根因：改人物尺寸後沒同步檢查站位間距。
3. 熱氣球飄太高（y 10），預設取景只剩一條繩子。根因：取景框只框地面高度 3.5 公尺。
4. 第一次用 SHOWORK_OFFICE_FOCUS=dog 截近照，鏡頭對到小狗「還沒跑過去前」的位置。根因：FOCUS 預設 2 秒就飛，資料讀完小狗才移動 → 要加 SHOWORK_OFFICE_PROBE_DELAY=4。
5. 差點把私人專案名／店名寫進原始碼（這是公開 repo）。改成 local.json 的 "village"，原始碼只留通用預設與 Okle42。

## 下次加速
- 先用 `--board-window` + `SHOWORK_OFFICE_DEMO=all` + `SHOWORK_TEST_SHOT` 截圖看比例，再進真資料（離屏、不搶焦點，6 秒一張）。
- 新場景先把「座標表＋找路＋位置規則」放 ShoWorkCore 寫測試（站位不在房子裡、障礙不重疊），美術只管畫；這次座標測試一次抓到撞樹。
- 角色放大時，同時改：站位間距、小狗站旁邊的距離、名牌錨點、點擊盒。
- 私人名字一律走 LocalConfig（local.json），動工前先 `grep` 公開 repo 有沒有那些字。

## 新流程（3D 場景改版）
1. 讀 OfficeBuilder／OfficeSCNView 有哪些路由點（labelTargets、personNode、frameCamera、updateLOD、pick）。
2. 規則與座標放 ShoWorkCore，先寫測試（歸屬、站位、障礙、找路）。
3. 美術寫成獨立 builder，掛在 OfficeBuilder 下用開關切換，舊場景整個保留。
4. 離屏測試視窗截白天全景／近照／夜晚三張，看比例再修。
5. `swift build`＋`swift test` 全過才 commit（分階段）。
6. `scripts/showork_install.py install` 裝到本機，開 App 用 `screencapture -x -o -l <視窗編號>` 截真資料。
7. 私人設定寫進 local.json（不進 git），回報時講清楚動過哪些本機檔。
