// OfficeBasement.swift 的掛點（11-01 P0 地基）：B1 機房＋浮空神經網路。現在只有 root（name "basement"）與常數；
// 本體由轉寫 OfficeBasement.swift 的 agent 填進來。

import { scnNode, TD } from "../kit.js";

export class OfficeBasement {
  /** B1 專用的光照位元（大樓 1、角色點擊 2、戶外 1<<4） */
  static mask = 1 << 5;
  static floorY = -5.6;
  static clear = 5.2;
  static baseY = -5.6 - TD.room;
  static bottomY = -5.6 - TD.room - 1.5;

  constructor() {
    this.root = scnNode("basement");
    this.root.visible = false;               // 鏡頭到地下才出現（setLive）
    this.facades = [];
    this.spinning = false;
  }
  setPower(p) {}
  setLive(on, spin) { this.root.visible = on; }   // TODO(轉寫)：自轉、淡入
  setGraph(g) {}
}
