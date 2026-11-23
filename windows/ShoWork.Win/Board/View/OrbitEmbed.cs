using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("Orbit42")]

namespace ShoWork;

/// 11-23 Orbit42 Windows 版：Mac SphereEmbed.swift 的對應。Orbit42.exe 把整個 ShoWork 引擎（光暈、pipe、戰情中心）跑在自己裡面，
/// 主視窗＝戰情中心的球體鋪滿（BoardForm Orbit 模式），衛星終端機小視窗由 Orbit42 自己蓋在上面。
/// 沒有 Orbit42 時（一般 ShoWorkAgent）這裡全是 null／false，行為不變。
public static class OrbitEmbed
{
    /// Orbit42 在跑（球體帶 ?orbit=1、戰情中心只留球體）
    public static bool Active { get; set; }

    public sealed record SessionRef(string SessionId, int Pid, string? Kind, string? Cwd, string Name);

    /// 點到球上的衛星：Orbit42 能自己開（它的終端機）就回 true；false＝照舊跳到那個終端機視窗
    public static Func<SessionRef, bool>? OpenSession { get; set; }
    /// 球體工具列「＋ 新衛星」（brain：claude／codex／gemini；"accounts"＝打開帳號頁）
    public static Action<string>? NewSatellite { get; set; }
    /// Orbit42 自己的按鈕：fullscreen、theme:dark|light、arrangeSats:x,y,w,h
    public static Action<string>? Command { get; set; }
    /// 戰情中心（Orbit 模式）建好了：Orbit42 把登入畫面、衛星小視窗加到這個視窗上
    public static Action<Form>? BoardReady { get; set; }

    /// 球體網頁（Orbit42 要問答案卡位置、衛星可用範圍、播過場動畫）
    internal static SphereHost? Sphere { get; set; }

    /// 在球體網頁跑一段 JS，回傳結果（JSON 字串；球體還沒好回 null）
    public static Task<string?> Eval(string js) => Sphere?.Eval(js) ?? Task.FromResult<string?>(null);
}
