// OfficeRain.swift（WeatherFX）的掛點（11-01 P0 地基）：現在只有 attach（雨的 rig 掛在鏡頭下、閃電用的 ambient 燈），
// 雨、閃電、擋雨盒由轉寫 OfficeRain.swift 的 agent 填進來。

import { scnLight, scnNode, SColor } from "../kit.js";

export class WeatherFX {
  constructor() {
    this.rig = scnNode("weather-rain");
    this.flash = null;
    this.raining = false;
  }
  attach(camera, scene) {
    this.camera = camera;
    this.rig.renderOrder = 1000;            // 在擋雨盒（900）之後畫
    camera.add(this.rig);
    this.flash = scnLight({ type: "ambient", color: new SColor(0.82, 0.86, 1.0), intensity: 0 });
    this.flash.visible = false;
    scene.add(this.flash);
  }
  follow(pov) { return false; }
  set(w) { return false; }
  setDark(d) {}
  setHidden(h) {}
  setInside(i) {}
  size(dist) {}
  aim() {}
  shelter(world, lo, hi) {}
}
