import AppKit
import ShoWorkCore

/// 11-23：Orbit42 取代 ShoWorkAgent——同一顆引擎（ShoWorkAgentMain.run），加上 Orbit42 自己的主視窗。
public struct AgentOptions {
    public var regularApp: Bool                        // true＝一般 App（Dock 圖示、選單列）；ShoWorkAgent 是 false
    public var onLaunch: (@MainActor () -> Void)?      // 引擎起來之後呼叫（Orbit42 在這裡開主視窗）
    public var waitForAccessibility: Bool               // false＝沒有輔助使用權限也照樣跑（Orbit42：問一次就繼續）
    public var testOnly: Bool                           // true＝只開視窗（螢幕外測試用；不開引擎、不碰正在跑的 ShoWorkAgent）
    public init(regularApp: Bool = false, waitForAccessibility: Bool = true, testOnly: Bool = false, onLaunch: (@MainActor () -> Void)? = nil) {
        self.regularApp = regularApp; self.waitForAccessibility = waitForAccessibility; self.testOnly = testOnly; self.onLaunch = onLaunch
    }
    /// 測試模式（螢幕外、不准開到使用者螢幕、不准真的動手）
    @MainActor public static var isTest: Bool { BoardWindow.testMode }
}

/// 球體嵌進別的 App（Orbit42）用的接口：完整的球體畫面（播報、空白鍵講話、量表、自檢、cool42…全部同一份），
/// 點衛星／新衛星交給宿主處理。
@MainActor
public enum SphereEmbed {
    public struct SessionRef: Sendable {
        public let sessionId: String
        public let pid: Int32
        public let jobId: String?
        public let kind: String?
        public let cwd: String?
        public let name: String
    }
    /// 點衛星：回 true＝宿主處理掉了（開它的終端機）；false＝照舊（跳 Ghostty 視窗／attach）
    public static var openSession: ((SessionRef) -> Bool)?
    /// 球體工具列「＋ 新衛星」（brain：claude／gemini／codex）
    public static var newSatellite: ((String) -> Void)?
    /// 宿主自己的指令（球體 ?orbit=1 才有的按鈕，例如 "fullscreen"）
    public static var command: ((String) -> Void)?
    /// 11-23 Orbit42 iPhone App：球體最新一份 karaUpdate 資料（手機版球體用同一份）
    public internal(set) static var latestSphere: Data?
    /// 11-23 Orbit42 iPhone App：衛星清單（JSON 陣列）與某顆衛星的終端機輸出（從第 from 個位元組起；JSON {total, from, data(base64)}）。Orbit42 設定
    public static var remoteSats: (() -> Data)?
    public static var remoteScreen: ((String, Int) -> Data?)?
    /// 11-24 iPhone 衛星終端機可操作：把手機送來的位元組（鍵盤、滑鼠跳脫序列）寫進那顆衛星的終端機；找不到衛星回 false。Orbit42 設定
    public static var remoteInput: ((String, Data) -> Bool)?

    private static var hosts: [SphereWebHost] = []

    /// 11-23 T1123115042：戰情中心自己持有的 session（kind board，例如隊長）的對話內容，給 Orbit42 裝進衛星終端機外框。
    /// 這類 session 是引擎用 claude -p 串流跑的，不是終端機程式，沒辦法 attach；內容用工作視窗那份網頁（?orbit=1 黑白灰紅、透明底）
    public static func workView(sessionId: String, cwd: String?, theme: String) -> NSView? {
        WorkWindow.embedded(SessionHost.shared.handle(for: sessionId) ?? sessionId, cwd: cwd, theme: theme)
    }
    public static func closeWorkView(sessionId: String) {
        WorkWindow.closeEmbedded(SessionHost.shared.handle(for: sessionId) ?? sessionId)
    }
    public static func workTheme(_ theme: String) { WorkWindow.setOrbitTheme(theme) }

    /// 完整球體（跟戰情中心的球體分頁同一份 sphere.html，多帶 ?orbit=1 顯示 Orbit42 才有的按鈕）
    public static func makeView() -> NSView {
        guard let h = SphereWebHost(orbit: true) else {
            let t = NSTextField(labelWithString: "找不到 sphere.html（Web 資料夾）"); t.alignment = .center; return t
        }
        hosts.append(h)
        return h.web
    }
}
