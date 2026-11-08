# 3D 素材

- `models/`：辦公室物件的 glTF（自製）。檔名照 `scene/props.js` 的物件表（清單也在 docs/OWN-SESSIONS.md「3D 物件清單」），
  做好一個就放進來，再把檔名加進 `models/manifest.json`。沒列的物件用程式畫的佔位方塊。
- 11-08 曾短暫用過 Kenney 的 CC0 素材包，使用者決定 3D 素材自己做一套，已拿掉。

`vendor/three-r170/loaders/GLTFLoader.js`、`vendor/three-r170/utils/BufferGeometryUtils.js`、`vendor/three-r170/utils/SkeletonUtils.js` 是 three.js r170 官方 examples（MIT，見 `vendor/three-r170/LICENSE`）。
