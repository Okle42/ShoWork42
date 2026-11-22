import AppKit
import Metal
import SceneKit
import ShoWorkCore

// 畫面風格（10-22 Kang）：模型不動，只換鏡頭＋一道全螢幕後製（SCNTechnique）。
//   微縮模型：正交鏡頭（沒有近大遠小）、35° 方位＋15° 俯角；上下明顯模糊（移軸）、粉彩霧面、木頭底座＋桌面＋暗角 ⇒ 像桌上的模型屋
//   藍圖：深藍底＋格線；物體邊緣（深度與顏色的變化）畫成發光青線；高彩度的顏色（狀態紅／橘／綠）保留
// 名牌、狀態標籤是疊在 3D 上的圖層，不經過後製，所以照樣看得清楚。
// 省電：後製只在有渲染時跑（按需渲染，靜止時不畫）；shader 執行期編譯一次（不需要 Xcode 的 metal 工具）。

@MainActor
enum OfficeStyleFX {
    private static var library: MTLLibrary?
    private static var cache: [OfficeStyle: SCNTechnique] = [:]

    static func technique(_ s: OfficeStyle, device: MTLDevice?) -> SCNTechnique? {
        guard s != .voxel, let device else { return nil }
        if let t = cache[s] { return t }
        if library == nil {
            do { library = try device.makeLibrary(source: shaderSource, options: nil) }
            catch { Log.note("風格 shader 編譯失敗：\(error)"); return nil }
        }
        let frag = s == .diorama ? "sw_diorama" : "sw_blueprint"
        let def: [String: Any] = [
            "passes": ["fx": [
                "draw": "DRAW_QUAD",
                "metalVertexShader": "sw_quad",
                "metalFragmentShader": frag,
                "inputs": ["colorSampler": "COLOR", "depthSampler": "DEPTH"],
                "outputs": ["color": "COLOR"],
            ]],
            "sequence": ["fx"],
        ]
        guard let t = SCNTechnique(dictionary: def) else { return nil }
        t.library = library
        cache[s] = t
        return t
    }

    /// 正交鏡頭時，鏡頭距離 → 畫面一半高（對到原本 34° 透視在那個距離看到的大小）
    static func orthoScale(dist: Double, fov: Double = 34) -> Double { dist * tan(fov / 2 * .pi / 180) * 1.2 }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VIn { float4 position [[attribute(0)]]; };
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut sw_quad(VIn in [[stage_in]]) {
        VOut o; o.position = in.position;
        o.uv = float2((in.position.x + 1.0) * 0.5, 1.0 - (in.position.y + 1.0) * 0.5);
        return o;
    }
    constexpr sampler smp(coord::normalized, filter::linear, address::clamp_to_edge);

    fragment half4 sw_diorama(VOut in [[stage_in]], texture2d<float, access::sample> colorSampler [[texture(0)]],
                              depth2d<float, access::sample> depthSampler [[texture(1)]]) {
        float2 uv = in.uv;
        float2 px = 1.0 / float2(colorSampler.get_width(), colorSampler.get_height());
        // 移軸：中間約 25% 清楚，往上下明顯糊掉（10-22 Kang「跟體素太像」⇒ 加重）
        float d = abs(uv.y - 0.52);
        float k = smoothstep(0.12, 0.42, d);
        float r = k * 9.0;
        float dc = depthSampler.sample(smp, uv);
        float3 c = colorSampler.sample(smp, uv).rgb;
        if (r > 0.05) {
            float3 acc = c; float w = 1.0;
            for (int i = 1; i <= 6; i++) {
                float o = r * float(i) / 6.0;
                float wi = 1.0 - float(i) / 7.0;
                acc += (colorSampler.sample(smp, uv + float2(o, 0) * px).rgb + colorSampler.sample(smp, uv - float2(o, 0) * px).rgb
                      + colorSampler.sample(smp, uv + float2(0, o) * px).rgb + colorSampler.sample(smp, uv - float2(0, o) * px).rgb
                      + colorSampler.sample(smp, uv + float2(o, o) * px * 0.7).rgb + colorSampler.sample(smp, uv - float2(o, o) * px * 0.7).rgb) * wi;
                w += 6.0 * wi;
            }
            c = acc / w;
        }
        if (dc <= 0.00001 || dc >= 0.99999) {
            // 底座外面＝桌面：深色木頭，上亮下暗＋細木紋
            float grain = sin(uv.y * 340.0 + sin(uv.x * 9.0) * 3.0) * 0.5 + 0.5;
            c = mix(float3(0.20, 0.13, 0.08), float3(0.34, 0.23, 0.14), 1.0 - uv.y) * (0.93 + 0.07 * grain);
        } else {
            // 粉彩霧面漆：對比降、暗部提亮、帶一點白；高彩度（狀態紅／橘／綠）保留
            float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
            float sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
            float keep = smoothstep(0.55, 0.8, sat) * smoothstep(0.35, 0.6, mx);
            float l = dot(c, float3(0.299, 0.587, 0.114));
            float3 p = mix(float3(l), c, 0.85) * 0.80 + float3(0.20, 0.19, 0.17) * smoothstep(0.04, 0.45, l);   // 暗部（夜晚）不提亮，不然一片灰霧
            p *= float3(1.04, 1.0, 0.94);
            c = mix(p, c, keep);
        }
        // 暗角：四周壓暗，像對著桌上模型拍的照片
        float2 q = (uv - 0.5) * float2(1.3, 1.0);
        c *= 1.0 - 0.38 * smoothstep(0.35, 0.8, length(q));
        return half4(half3(clamp(c, 0.0, 1.0)), 1.0);
    }

    fragment half4 sw_blueprint(VOut in [[stage_in]], texture2d<float, access::sample> colorSampler [[texture(0)]],
                                depth2d<float, access::sample> depthSampler [[texture(1)]]) {
        float2 uv = in.uv;
        float2 sz = float2(colorSampler.get_width(), colorSampler.get_height());
        float2 px = 1.0 / sz;
        float dc = depthSampler.sample(smp, uv);
        // 深度邊緣：用相對差（透視深度不是線性的，近的物體差值小）
        float dmax = 0.0, cmax = 0.0;
        float3 c0 = colorSampler.sample(smp, uv).rgb;
        float l0 = dot(c0, float3(0.299, 0.587, 0.114));
        float2 offs[4] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1) };
        for (int i = 0; i < 4; i++) {
            float dn = depthSampler.sample(smp, uv + offs[i] * px);
            float big = max(dc, dn);
            if (big > 0.015) dmax = max(dmax, abs(dn - dc) / big);     // 天空（反向深度＝0 附近）不算邊，不然整片雜訊變亮帶
            float ln = dot(colorSampler.sample(smp, uv + offs[i] * px).rgb, float3(0.299, 0.587, 0.114));
            cmax = max(cmax, abs(ln - l0));
        }
        float edge = max(smoothstep(0.004, 0.02, dmax), smoothstep(0.08, 0.22, cmax) * 0.7);
        bool sky = dc <= 0.015 || dc >= 1.0;     // 遠處大地面（反向深度很小）跟天空一樣當底
        float3 navy = float3(0.03, 0.09, 0.20);
        // 格線：每 32 點一條細線、每 160 點一條粗一點
        float2 g = fmod(in.position.xy, 32.0);
        float2 G = fmod(in.position.xy, 160.0);
        float grid = (min(g.x, g.y) < 1.0 ? 0.06 : 0.0) + (min(G.x, G.y) < 1.5 ? 0.06 : 0.0);
        float3 col = navy + float3(0.25, 0.55, 0.85) * grid;
        if (!sky) col = mix(col, float3(0.10, 0.30, 0.55), 0.18 + 0.35 * l0);   // 物體：比底色亮一點（亮的面更亮）
        col = mix(col, float3(0.55, 0.88, 1.0), edge);
        // 高彩度（狀態紅／橘／綠、發光的螢幕）保留原色
        float mx = max(c0.r, max(c0.g, c0.b)), mn = min(c0.r, min(c0.g, c0.b));
        float sat = mx > 0.0 ? (mx - mn) / mx : 0.0;
        col = mix(col, c0 * 1.1, smoothstep(0.55, 0.8, sat) * smoothstep(0.35, 0.6, mx) * (sky ? 0.0 : 1.0));
        return half4(half3(clamp(col, 0.0, 1.0)), 1.0);
    }
    """
}
