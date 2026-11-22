import AppKit
import ShoWorkCore

// 戰情中心自己持有的 session 的動作（11-08 H2，docs/OWN-SESSIONS.md）：送話、中斷、交棒到終端機、搬進戰情中心。
// 送話時才接回（SessionHost.ensure）：終端機那邊結束後，在戰情中心送話就自動接回，不用另外按。

@MainActor
enum OwnedActions {
    static var host: SessionHost { SessionHost.shared }

    /// 開新工作（取代 claude --bg）：開好就送第一句；回傳 session id 或錯誤
    static func start(cwd: String, prompt: String, model: String? = nil, name: String? = nil,
                      permissionMode: String? = nil) -> Result<String, CardError> {
        do {
            let s = try host.start(cwd: cwd, model: model, name: name, permissionMode: permissionMode)
            if !prompt.isEmpty { s.send(prompt) }
            BoardModel.shared.append(["ev": "own-start", "id": s.sessionId, "folder": cwd, "prompt": prompt])
            return .success(s.sessionId)
        } catch {
            return .failure(CardError("\(error)"))
        }
    }

    /// 送一句話（content：字串，或含圖片的區塊陣列）
    static func send(_ sid: String, content: Any, cwd: String? = nil) -> String? {
        do {
            let s = try host.ensure(sid, cwd: cwd)
            guard s.send(content: content) else { return "送不出去：程序已經結束" }
            return nil
        } catch let e as SessionHostError {
            return e.description
        } catch {
            return "\(error)"
        }
    }

    static func interrupt(_ sid: String) -> String {
        guard let s = host.session(sid) else { return "這個 session 沒有在戰情中心跑" }
        return s.interrupt() ? "已中斷" : "中斷失敗：程序已經結束"
    }

    /// 交棒到終端機：先關掉戰情中心的程序，再開一個 Ghostty 視窗跑 `claude --resume`。
    /// 不用 `ghostty -e`（會啟動第二份 Ghostty 並還原上次的視窗）；開不了 Ghostty 就把指令拷貝到剪貼簿
    static func openInTerminal(_ sid: String) -> String {
        guard host.release(sid) else { return "戰情中心的程序關不掉，沒有交棒" }
        let r = host.owners()[sid]
        let cwd = r?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        var cmd = "claude --resume \(r?.liveId ?? sid)"
        if let m = r?.model { cmd += " --model \(m)" }
        BoardModel.shared.append(["ev": "own-to-terminal", "id": sid])
        if Script.run(ghosttyScript(cwd: cwd, input: cmd))?.stringValue == "ok" {
            return "已在終端機打開；那邊結束後，在這裡送話就會接回來"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(host.terminalCommand(sid), forType: .string)
        return "開不了 Ghostty（\(Script.lastError ?? "未知原因")）；接手指令已拷貝，貼到任何終端機執行"
    }

    nonisolated static func ghosttyScript(cwd: String, input: String) -> String {
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        return """
            tell application id "com.mitchellh.ghostty"
              set cfg to new surface configuration
              set initial working directory of cfg to "\(q(cwd))"
              set initial input of cfg to "\(q(input))\\n"
              new window with configuration cfg
              activate
              return "ok"
            end tell
            """
    }

    /// 搬進戰情中心：舊 session（終端機開的）在那邊結束後接過來；還在跑就說要先結束
    static func moveIn(_ sid: String, cwd: String) -> String {
        do {
            _ = try host.ensure(sid, cwd: cwd)
            BoardModel.shared.append(["ev": "own-move-in", "id": sid])
            return "已搬進戰情中心"
        } catch let e as SessionHostError {
            return e.description
        } catch {
            return "\(error)"
        }
    }

    /// 結束（關掉程序；紀錄留著，之後送話還能接回）
    static func close(_ sid: String) -> String {
        host.release(sid, to: .board) ? "已關掉；之後送話會自動接回" : "關不掉"
    }
}
