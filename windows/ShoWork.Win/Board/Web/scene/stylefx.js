// OfficeStyleFX.swift 照搬（11-02 P8）：畫面風格的全螢幕後製（SCNTechnique → 一個 render target＋全螢幕四邊形）。
//
// 畫面風格（10-22 Kang）：模型不動，只換鏡頭＋一道全螢幕後製。
//   微縮模型（diorama）：正交鏡頭（沒有近大遠小）、35° 方位＋15° 俯角；上下明顯模糊（移軸）、粉彩霧面、木頭底座＋桌面＋暗角 ⇒ 像桌上的模型屋
//   藍圖（blueprint）：深藍底＋格線；物體邊緣（深度與顏色的變化）畫成發光青線；高彩度的顏色（狀態紅／橘／綠）保留
// 名牌、狀態標籤是疊在 3D 上的 HTML 圖層，不經過後製，所以照樣看得清楚。
// 省電：後製只在有渲染時跑（按需渲染，靜止時不畫）。
//
// Swift → JS 的差別（shader 逐行照 Metal 抄，只換這幾處）：
//   · uv：Metal 的 uv 原點在左上（y 往下）；這裡 mtl(uv) 換算，取樣一律經過 S()／SD()，公式完全照抄。
//   · 深度：Metal 是反向 Z（近 1、遠 0）；WebGL 的深度貼圖是一般 Z（近 0、遠 1）。透視投影下「1 − 一般 Z」剛好等於反向 Z ⇒ SD() 回 1 − d。
//   · in.position.xy（像素、左上原點）→ vec2(gl_FragCoord.x, 高 − gl_FragCoord.y)。
//   · 顏色空間：SceneKit 的 COLOR 輸入假設是線性（沒有 Mac 的量尺，這點未實測）；輸出經過 colorspace_fragment 轉 sRGB。
//   · HDR bloom／暗角（ScnPost）在有風格時不跑（SceneKit 的 technique 跟相機後製怎麼疊，Mac 沒有量尺）。
// 用法：const t = OfficeStyleFX.technique("diorama"|"blueprint")；每幀 t ? t.render(renderer, scene, camera) : post.render(...)。
//       鏡頭正交時 camera 的半高＝OfficeStyleFX.orthoScale(dist)（Swift 的 orthographicScale）。

import * as THREE from "three";

const VS = "varying vec2 vUv; void main() { vUv = uv; gl_Position = vec4(position.xy, 0.0, 1.0); }";

const COMMON = `
uniform sampler2D colorSampler;
uniform sampler2D depthSampler;
uniform vec2 uSize;
varying vec2 vUv;
// Metal 座標（左上原點）→ GL 取樣
vec3 S(vec2 u) { return texture2D(colorSampler, vec2(u.x, 1.0 - u.y)).rgb; }
float SD(vec2 u) { return 1.0 - texture2D(depthSampler, vec2(u.x, 1.0 - u.y)).r; }
`;

const DIORAMA = COMMON + `
void main() {
  vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
  vec2 px = 1.0 / uSize;
  // 移軸：中間約 25% 清楚，往上下明顯糊掉（10-22 Kang「跟體素太像」⇒ 加重）
  float d = abs(uv.y - 0.52);
  float k = smoothstep(0.12, 0.42, d);
  float r = k * 9.0;
  float dc = SD(uv);
  vec3 c = S(uv);
  if (r > 0.05) {
    vec3 acc = c; float w = 1.0;
    for (int i = 1; i <= 6; i++) {
      float o = r * float(i) / 6.0;
      float wi = 1.0 - float(i) / 7.0;
      acc += (S(uv + vec2(o, 0.0) * px) + S(uv - vec2(o, 0.0) * px)
            + S(uv + vec2(0.0, o) * px) + S(uv - vec2(0.0, o) * px)
            + S(uv + vec2(o, o) * px * 0.7) + S(uv - vec2(o, o) * px * 0.7)) * wi;
      w += 6.0 * wi;
    }
    c = acc / w;
  }
  if (dc <= 0.00001 || dc >= 0.99999) {
    // 底座外面＝桌面：深色木頭，上亮下暗＋細木紋
    float grain = sin(uv.y * 340.0 + sin(uv.x * 9.0) * 3.0) * 0.5 + 0.5;
    c = mix(vec3(0.20, 0.13, 0.08), vec3(0.34, 0.23, 0.14), 1.0 - uv.y) * (0.93 + 0.07 * grain);
  } else {
    // 粉彩霧面漆：對比降、暗部提亮、帶一點白；高彩度（狀態紅／橘／綠）保留
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
    float keep = smoothstep(0.55, 0.8, sat) * smoothstep(0.35, 0.6, mx);
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    vec3 p = mix(vec3(l), c, 0.85) * 0.80 + vec3(0.20, 0.19, 0.17) * smoothstep(0.04, 0.45, l);   // 暗部（夜晚）不提亮，不然一片灰霧
    p *= vec3(1.04, 1.0, 0.94);
    c = mix(p, c, keep);
  }
  // 暗角：四周壓暗，像對著桌上模型拍的照片
  vec2 q = (uv - 0.5) * vec2(1.3, 1.0);
  c *= 1.0 - 0.38 * smoothstep(0.35, 0.8, length(q));
  gl_FragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
  #include <colorspace_fragment>
}`;

const BLUEPRINT = COMMON + `
void main() {
  vec2 uv = vec2(vUv.x, 1.0 - vUv.y);
  vec2 px = 1.0 / uSize;
  float dc = SD(uv);
  // 深度邊緣：用相對差（透視深度不是線性的，近的物體差值小）
  float dmax = 0.0, cmax = 0.0;
  vec3 c0 = S(uv);
  float l0 = dot(c0, vec3(0.299, 0.587, 0.114));
  vec2 offs[4];
  offs[0] = vec2(1.0, 0.0); offs[1] = vec2(-1.0, 0.0); offs[2] = vec2(0.0, 1.0); offs[3] = vec2(0.0, -1.0);
  for (int i = 0; i < 4; i++) {
    float dn = SD(uv + offs[i] * px);
    float big = max(dc, dn);
    if (big > 0.015) dmax = max(dmax, abs(dn - dc) / big);     // 天空（反向深度＝0 附近）不算邊，不然整片雜訊變亮帶
    float ln = dot(S(uv + offs[i] * px), vec3(0.299, 0.587, 0.114));
    cmax = max(cmax, abs(ln - l0));
  }
  float edge = max(smoothstep(0.004, 0.02, dmax), smoothstep(0.08, 0.22, cmax) * 0.7);
  bool sky = dc <= 0.015 || dc >= 1.0;     // 遠處大地面（反向深度很小）跟天空一樣當底
  vec3 navy = vec3(0.03, 0.09, 0.20);
  // 格線：每 32 點一條細線、每 160 點一條粗一點
  vec2 pos = vec2(gl_FragCoord.x, uSize.y - gl_FragCoord.y);
  vec2 g = mod(pos, 32.0);
  vec2 G = mod(pos, 160.0);
  float grid = (min(g.x, g.y) < 1.0 ? 0.06 : 0.0) + (min(G.x, G.y) < 1.5 ? 0.06 : 0.0);
  vec3 col = navy + vec3(0.25, 0.55, 0.85) * grid;
  if (!sky) col = mix(col, vec3(0.10, 0.30, 0.55), 0.18 + 0.35 * l0);   // 物體：比底色亮一點（亮的面更亮）
  col = mix(col, vec3(0.55, 0.88, 1.0), edge);
  // 高彩度（狀態紅／橘／綠、發光的螢幕）保留原色
  float mx = max(c0.r, max(c0.g, c0.b)), mn = min(c0.r, min(c0.g, c0.b));
  float sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
  col = mix(col, c0 * 1.1, smoothstep(0.55, 0.8, sat) * smoothstep(0.35, 0.6, mx) * (sky ? 0.0 : 1.0));
  gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
  #include <colorspace_fragment>
}`;

/** 一個風格的後製（SCNTechnique 的替身）：先把場景畫進帶深度貼圖的 render target，再用全螢幕四邊形跑 shader 畫到畫面 */
class StyleTechnique {
  constructor(frag) {
    this.mat = new THREE.ShaderMaterial({
      uniforms: { colorSampler: { value: null }, depthSampler: { value: null }, uSize: { value: new THREE.Vector2(1, 1) } },
      vertexShader: VS, fragmentShader: frag, depthTest: false, depthWrite: false,
    });
    this.quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2), this.mat);
    this.quad.frustumCulled = false;
    this.scene = new THREE.Scene(); this.scene.add(this.quad);
    this.cam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    this.rt = null;
    this.size = new THREE.Vector2();
  }
  ensure(w, h) {
    if (this.rt && this.rt.width === w && this.rt.height === h) return;
    this.rt?.dispose();
    this.rt = new THREE.WebGLRenderTarget(w, h, { type: THREE.HalfFloatType, depthTexture: new THREE.DepthTexture(w, h, THREE.FloatType) });
    this.rt.depthTexture.minFilter = this.rt.depthTexture.magFilter = THREE.NearestFilter;
  }
  render(renderer, scene, camera) {
    renderer.getDrawingBufferSize(this.size);
    const w = this.size.x, h = this.size.y;
    this.ensure(w, h);
    renderer.setRenderTarget(this.rt); renderer.render(scene, camera);
    this.mat.uniforms.colorSampler.value = this.rt.texture;
    this.mat.uniforms.depthSampler.value = this.rt.depthTexture;
    this.mat.uniforms.uSize.value.set(w, h);
    renderer.setRenderTarget(null); renderer.render(this.scene, this.cam);
  }
  dispose() { this.rt?.dispose(); this.mat.dispose(); this.quad.geometry.dispose(); }
}

export const OfficeStyleFX = {
  cache: new Map(),

  /** style＝"voxel"（沒有後製，回 null）｜"diorama"｜"blueprint"。shader 第一次用時編譯，之後共用 */
  technique(s) {
    if (s === "voxel" || !s) return null;
    if (OfficeStyleFX.cache.has(s)) return OfficeStyleFX.cache.get(s);
    const t = new StyleTechnique(s === "diorama" ? DIORAMA : BLUEPRINT);
    OfficeStyleFX.cache.set(s, t);
    return t;
  },

  /** 正交鏡頭時，鏡頭距離 → 畫面一半高（對到原本 34° 透視在那個距離看到的大小） */
  orthoScale(dist, fov = 34) { return dist * Math.tan(fov / 2 * Math.PI / 180) * 1.2; },
};
