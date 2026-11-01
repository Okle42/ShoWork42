// ShoWorkCore/Solar.swift 照搬（11-01 P0）：太陽位置（NOAA）＋天色 SkyLook（依太陽仰角連續混合）。純函式、不碰 three。
// 顏色都是 sRGB 0–1 的 [r, g, b]；Date 用 JS Date。

const rad = d => d * Math.PI / 180, deg = r => r * 180 / Math.PI;
const fmod = (a, b) => a % b;     // Swift truncatingRemainder（同號規則一樣）

export const Solar = {
  taipei: { lat: 25.03, lon: 121.56 },
  declinationAndEqTime(date) {
    const jd = date.getTime() / 1000 / 86400 + 2440587.5;
    const jc = (jd - 2451545) / 36525;
    const l0 = fmod(280.46646 + jc * (36000.76983 + jc * 0.0003032), 360);
    const m = 357.52911 + jc * (35999.05029 - 0.0001537 * jc);
    const e = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc);
    const c = Math.sin(rad(m)) * (1.914602 - jc * (0.004817 + 0.000014 * jc)) + Math.sin(rad(2 * m)) * (0.019993 - 0.000101 * jc)
      + Math.sin(rad(3 * m)) * 0.000289;
    const trueLong = l0 + c;
    const omega = 125.04 - 1934.136 * jc;
    const appLong = trueLong - 0.00569 - 0.00478 * Math.sin(rad(omega));
    const meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60;
    const obliq = meanObliq + 0.00256 * Math.cos(rad(omega));
    const decl = deg(Math.asin(Math.sin(rad(obliq)) * Math.sin(rad(appLong))));
    const y = Math.pow(Math.tan(rad(obliq / 2)), 2);
    const eq = 4 * deg(y * Math.sin(2 * rad(l0)) - 2 * e * Math.sin(rad(m)) + 4 * e * y * Math.sin(rad(m)) * Math.cos(2 * rad(l0))
      - 0.5 * y * y * Math.sin(4 * rad(l0)) - 1.25 * e * e * Math.sin(2 * rad(m)));
    return { decl, eqTime: eq };
  },
  /** 太陽仰角＋方位角（NOAA，含大氣折射）：{ elevation, azimuth, rising } */
  position(date, lat = Solar.taipei.lat, lon = Solar.taipei.lon) {
    const { decl, eqTime } = this.declinationAndEqTime(date);
    const utcMin = fmod(date.getTime() / 1000, 86400) / 60;
    let tst = fmod(utcMin + eqTime + 4 * lon, 1440);
    if (tst < 0) tst += 1440;
    const ha = tst / 4 < 0 ? tst / 4 + 180 : tst / 4 - 180;
    const cz = Math.sin(rad(lat)) * Math.sin(rad(decl)) + Math.cos(rad(lat)) * Math.cos(rad(decl)) * Math.cos(rad(ha));
    const zenith = deg(Math.acos(Math.min(1, Math.max(-1, cz))));
    const el = 90 - zenith;
    let refr;
    if (el > 85) refr = 0;
    else {
      const te = Math.tan(rad(el));
      if (el > 5) refr = 58.1 / te - 0.07 / Math.pow(te, 3) + 0.000086 / Math.pow(te, 5);
      else if (el > -0.575) refr = 1735 + el * (-518.2 + el * (103.4 + el * (-12.79 + el * 0.711)));
      else refr = -20.772 / te;
    }
    const azDen = Math.cos(rad(lat)) * Math.sin(rad(zenith));
    let az;
    if (Math.abs(azDen) < 1e-9) az = lat > 0 ? 180 : 0;
    else {
      const a = (Math.sin(rad(lat)) * Math.cos(rad(zenith)) - Math.sin(rad(decl))) / azDen;
      const b = deg(Math.acos(Math.min(1, Math.max(-1, a))));
      az = ha > 0 ? fmod(b + 180, 360) : fmod(540 - b, 360);
    }
    return { elevation: el + refr / 3600, azimuth: az, rising: ha < 0 };
  },
};

const hex = h => [((h >>> 16) & 255) / 255, ((h >>> 8) & 255) / 255, (h & 255) / 255];

/** 一個時間點的天色與燈光參數（SkyLook）。sunDir：null＝美術固定角度；有值＝{ elevation, azimuth }（度） */
export function skyLook(o) {
  return { glowAmount: 0, overcast: 0, sunDir: null, ...o };
}

export const SkyLook = {
  hex,
  day: skyLook({ horizon: hex(0xD3DCE2), zenith: hex(0xA9BCCB), glow: hex(0xFFB070), glowAmount: 0, ground: hex(0xA4ABB0),
                 keyColor: hex(0xFFEBD2), keyIntensity: 600, ambientColor: hex(0xDCE6F0), ambientIntensity: 660,
                 fill: 340, moonFill: 0, dark: 0, lamps: 0, sunDir: null, fixed: "day" }),
  night: skyLook({ horizon: hex(0x141B26), zenith: hex(0x070A10), glow: hex(0x6A4A78), glowAmount: 0, ground: hex(0x0D1218),
                   keyColor: hex(0xA9B8DE), keyIntensity: 460, ambientColor: hex(0x8E9CC4), ambientIntensity: 260,
                   fill: 0, moonFill: 1500, dark: 1, lamps: 1, sunDir: null, fixed: "night" }),
  keySwitch: -4.0,
  // [e, hor, zen, glow, glowA, ground, key, keyI, amb, ambI, fill, moon, dark, lamps]
  morning: [
    [-12, 0x141B26, 0x070A10, 0x3A3060, 0, 0x0D1218, 0xA9B8DE, 460, 0x8E9CC4, 260, 0, 1500, 1, 1],
    [-9, 0x252A44, 0x0C1020, 0x4A3C70, 0.35, 0x111724, 0xA9B8DE, 330, 0x8E9CC6, 290, 0, 1250, 0.95, 1],
    [-6, 0x4A4670, 0x18223E, 0x8A6A9A, 0.5, 0x1A2030, 0xA9B8DE, 160, 0x9298C8, 340, 40, 800, 0.82, 0.92],
    [-4, 0x7A6A8E, 0x283652, 0xC8889A, 0.6, 0x363A52, 0xFF9A70, 0, 0xA6A0C8, 420, 80, 450, 0.68, 0.78],
    [-1.5, 0xC08890, 0x46587A, 0xF4A07C, 0.8, 0x606278, 0xFF8A5A, 220, 0xBCAEC6, 490, 150, 120, 0.48, 0.5],
    [1, 0xE6A088, 0x6A82A6, 0xFFA868, 0.9, 0x80828C, 0xFF9C5E, 420, 0xCABCC8, 555, 210, 0, 0.3, 0.22],
    [4, 0xEAB898, 0x86A0BE, 0xFFBC80, 0.7, 0x8A8E90, 0xFFB27A, 520, 0xD2CCD2, 580, 270, 0, 0.14, 0.04],
    [8, 0xDECCBC, 0x98B0C4, 0xFFD0A0, 0.4, 0x9A9FA2, 0xFFCDA0, 570, 0xD8DCE2, 630, 310, 0, 0.04, 0],
    [15, 0xD6D8DA, 0xA4BAC9, 0xFFE0C0, 0.12, 0xA2A9AE, 0xFFE2C4, 595, 0xDAE4EE, 655, 335, 0, 0, 0],
    [22, 0xD3DCE2, 0xA9BCCB, 0xFFB070, 0, 0xA4ABB0, 0xFFEBD2, 600, 0xDCE6F0, 660, 340, 0, 0, 0],
  ],
  evening: [
    [-12, 0x141B26, 0x070A10, 0x3A2A50, 0, 0x0D1218, 0xA9B8DE, 460, 0x8E9CC4, 260, 0, 1500, 1, 1],
    [-9, 0x2A2644, 0x0D1020, 0x5A3A6A, 0.4, 0x121624, 0xA9B8DE, 330, 0x8E9AC6, 290, 0, 1250, 0.95, 1],
    [-6, 0x5A426E, 0x1C2242, 0xA05A78, 0.6, 0x1C1E2C, 0xA9B8DE, 160, 0x9894C4, 340, 40, 800, 0.82, 0.9],
    [-4, 0x8E5A78, 0x2C3456, 0xD06A6A, 0.75, 0x3A3E56, 0xFF7A50, 0, 0xA098C0, 420, 80, 450, 0.68, 0.75],
    [-1.5, 0xD07A6E, 0x4A5478, 0xF48058, 0.9, 0x66667C, 0xFF7448, 240, 0xB8A8C0, 500, 150, 120, 0.48, 0.45],
    [1, 0xEC9466, 0x6C7EA0, 0xFF8C4A, 1, 0x84828A, 0xFF8648, 440, 0xD2B4AC, 560, 220, 0, 0.28, 0.22],
    [4, 0xEEAE76, 0x88A0BC, 0xFFA458, 0.8, 0x8E8C8A, 0xFFA25C, 540, 0xD8C4B6, 580, 280, 0, 0.12, 0.06],
    [10, 0xE4CCA8, 0x9CB2C4, 0xFFC27A, 0.45, 0x9EA2A2, 0xFFC890, 590, 0xDCD8D6, 635, 320, 0, 0.02, 0],
    [16, 0xD8D8D6, 0xA6BAC9, 0xFFD8A8, 0.15, 0xA3AAAE, 0xFFE0BC, 598, 0xDBE3EC, 655, 336, 0, 0, 0],
    [22, 0xD3DCE2, 0xA9BCCB, 0xFFB070, 0, 0xA4ABB0, 0xFFEBD2, 600, 0xDCE6F0, 660, 340, 0, 0, 0],
  ],
  isNight: l => l.dark >= 0.5,
  /** 依太陽位置混合（仰角 ≥ 22° 白天、≤ −12° 夜晚） */
  at(s) {
    const t = s.rising ? this.morning : this.evening, e = s.elevation;
    if (e >= t[t.length - 1][0]) return { ...this.day, fixed: null, sunDir: { elevation: Math.max(3, e), azimuth: s.azimuth } };
    if (e <= t[0][0]) return this.night;
    const i = t.findIndex(k => k[0] > e), a = t[i - 1], b = t[i];
    const f = (e - a[0]) / (b[0] - a[0]);
    const mix = (x, y) => x + (y - x) * f;
    const mixC = (x, y) => { const p = hex(x), q = hex(y); return [0, 1, 2].map(j => p[j] + (q[j] - p[j]) * f); };
    return skyLook({
      horizon: mixC(a[1], b[1]), zenith: mixC(a[2], b[2]), glow: mixC(a[3], b[3]), glowAmount: mix(a[4], b[4]),
      ground: mixC(a[5], b[5]), keyColor: e >= this.keySwitch ? mixC(a[6], b[6]) : hex(0xA9B8DE), keyIntensity: mix(a[7], b[7]),
      ambientColor: mixC(a[8], b[8]), ambientIntensity: mix(a[9], b[9]), fill: mix(a[10], b[10]), moonFill: mix(a[11], b[11]),
      dark: mix(a[12], b[12]), lamps: mix(a[13], b[13]),
      sunDir: e >= this.keySwitch ? { elevation: Math.max(3, e), azimuth: s.azimuth } : null,
    });
  },
};
