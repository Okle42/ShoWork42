// OfficeCity.swift 的掛點（11-01 P0 地基）：CityBuilder。現在只有 root（name "city"）跟鏡頭會用到的常數；
// 城市本體由轉寫 OfficeCity.swift 的 agent 填進來（update、setDark、shade 材質…），介面照 Swift。

import { scnNode, VoxMat, TD } from "../kit.js";

export class CityBuilder {
  // TODO(轉寫 OfficeCity.swift)：這些數字是從 Mac dump（mac-input.json 的 consts）抄的，轉寫時改成照 Swift 的式子算
  static x0 = -27; static x1 = 21; static z0 = -13; static z1 = 10;
  static streetZ = 14;
  static mainGateX = 2.0;
  static portX = 2.0;              // = mainGateX
  static branchX = 14.0;
  static laneZ = TD.zF + 0.75;
  static airshipDock(i) { return i === 0 ? [-22.4, 0, -11.2] : [0, 0, 0]; }
  /** 取景外框（frameCity）：Mac 的 CityBuilder.bounds */
  static get bounds() { return { lo: [-28, 0, -18], hi: [22, 9, 25.7] }; }
  /** 靜態假影子材質（applyLights 依太陽方向淡掉） */
  static get shade() { return VoxMat.dayNight(0xA9A59D, 0x141920); }
  static get shadeOut() { return VoxMat.dayNight(0x8C9297, 0x080B10); }

  constructor() {
    this.root = scnNode("city");
    this.state = { power: null };
  }
  update(s, animate) { this.state = s; return 0; }
  setDark(d) {}
  setSkylineHidden(h) {}
}
