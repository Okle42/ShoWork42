// ShoWork42.app 的本體：從「應用程式」、Spotlight、Launchpad、Dock 點下去就打開戰情中心。
// 真正的程式是常駐的 ShoWorkAgent（LaunchAgent，沒有 Dock 圖示）；這裡只負責「叫它出來」：
//   沒在跑 ⇒ launchctl 啟動它、等它的 socket 出現 ⇒ 送「打開戰情中心」通知（送兩次，防它剛起來還沒接上）⇒ 結束
import AppKit
import ShoWorkCore

let label = "ai.okle42.showork.agent"
let uid = getuid()

func agentRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["print", "gui/\(uid)/\(label)"]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return p.terminationStatus == 0 && s.contains("state = running")
}

func run(_ args: [String]) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
}

if !agentRunning() {
    let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    if FileManager.default.fileExists(atPath: plist) {
        run(["bootstrap", "gui/\(uid)", plist])
        run(["kickstart", "gui/\(uid)/\(label)"])
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: Paths.socket.path) { usleep(100_000) }
    } else {
        let a = NSAlert()
        a.messageText = "ShoWork42 還沒安裝"
        a.informativeText = "請先執行安裝程式（scripts/showork_install.py install）。"
        a.runModal()
        exit(1)
    }
}

let show = Notification.Name("ai.okle42.showork.showBoard")
DistributedNotificationCenter.default().postNotificationName(show, object: nil, userInfo: nil, deliverImmediately: true)
usleep(1_200_000)
DistributedNotificationCenter.default().postNotificationName(show, object: nil, userInfo: nil, deliverImmediately: true)
exit(0)
