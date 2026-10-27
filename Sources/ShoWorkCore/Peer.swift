import Foundation

// 直接把訊息送進另一個 Claude Code session 的收件匣（跟內建 SendMessage 同一條路，10-09 實測 2.1.290）：
//   ~/.claude/sessions/<pid>.json            messagingSocketPath（/tmp/cc-socks/<pid>.sock）
//   ~/.claude/sessions/<pid>.<hash>.key      {"peerToken": "…"}（0600，只有自己讀得到）
//   連上 socket → 一行 {"type":"auth","token":…} → 一行訊息 JSON，對方不回應。
// 訊息會排進對方收件匣，下一次用工具時才讀進去，不會打進輸入框。這是內部格式，Claude Code 改版可能失效：
// 失效時回傳錯誤，看板改提示用隊長 AI 的 SendMessage。
public enum Peer {
    public static var claudeDir: String {
        ProcessInfo.processInfo.environment["SHOWORK_CLAUDE_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"
    }

    /// 開著的 session（行程還在）
    public static func sessions() -> [SessionRecord] {
        let dir = claudeDir + "/sessions"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.compactMap {
            FileManager.default.contents(atPath: dir + "/" + $0).flatMap(SessionRecord.decode)
        }.filter { kill($0.pid, 0) == 0 || errno == EPERM }
    }

    /// 名字、英文短名（Chris）、sessionId 或它的開頭都可以；短名有兩個活的同名就回 nil（要錯誤訊息用 resolve）
    public static func find(_ who: String) -> SessionRecord? {
        if case .success(let r) = resolve(who) { return r }
        return nil
    }

    /// 同 find，但找不到／同名兩個活的會說清楚
    public static func resolve(_ who: String, nicknames: [String: Nickname]? = nil) -> Result<SessionRecord, CardError> {
        let all = sessions()
        let nick = (nicknames ?? NicknameStore.all()).mapValues(\.name)
        let hits = ShortName.match(who, among: all.map { ($0.sessionId, $0.name) }, nick: nick)
        let rs = hits.compactMap { sid in all.first { $0.sessionId == sid } }
        switch rs.count {
        case 1: return .success(rs[0])
        case 0: return .failure(CardError("找不到開著的 session「\(who)」"))
        default: return .failure(CardError("「\(who)」有 \(rs.count) 個開著的 session，請用全名或 sessionId：" + rs.map { "\($0.name ?? "?")（\($0.sessionId.prefix(8))）" }.joined(separator: "、")))
        }
    }

    /// 訊息本體（純函式，測試用）
    public static func lines(token: String, text: String, fromName: String, replyTo: String?, id: String) -> [String] {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;") }
        let from = "uds:" + (replyTo ?? "")
        let body = "<cross-session-message from=\"\(esc(from))\" from-name=\"\(esc(fromName))\">\n\(text)\n</cross-session-message>"
        let auth: [String: Any] = ["type": "auth", "token": token]
        let msg: [String: Any] = ["msgV": 1, "msg_id": id, "type": "user", "priority": "next", "from": from,
                                  "message": ["role": "user", "content": body]]
        return [auth, msg].compactMap { (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } }
    }

    /// 送出；成功回傳訊息 id
    public static func send(to r: SessionRecord, text: String, fromName: String, replyTo: String? = nil) -> Result<String, CardError> {
        if Handover.shouldHold(sid: r.sessionId, fromName: fromName) {   // 收尾中：先暫存，新 context 接手時一起給（T1026230337）
            Handover.hold(sid: r.sessionId, text: text, fromName: fromName)
            return .success("held")
        }
        guard let path = r.messagingSocketPath else { return .failure(CardError("\(r.name ?? r.sessionId) 沒有收件匣（版本太舊或是背景 session）")) }
        let dir = claudeDir + "/sessions"
        guard let kf = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).first(where: { $0.hasPrefix("\(r.pid).") && $0.hasSuffix(".key") }),
              let kd = FileManager.default.contents(atPath: dir + "/" + kf),
              let token = (try? JSONSerialization.jsonObject(with: kd) as? [String: Any])?["peerToken"] as? String else {
            return .failure(CardError("找不到 \(r.name ?? r.sessionId) 的收件鑰匙"))
        }
        let id = UUID().uuidString.lowercased()
        let data = Data(lines(token: token, text: text, fromName: fromName, replyTo: replyTo, id: id).map { $0 + "\n" }.joined().utf8)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(CardError("開不了 socket")) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .failure(CardError("socket 路徑太長")) }
        withUnsafeMutableBytes(of: &addr.sun_path) { b in path.utf8.enumerated().forEach { b[$0.offset] = $0.element } }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { return .failure(CardError("連不上 \(r.name ?? r.sessionId) 的收件匣（errno \(errno)）")) }
        let n = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard n == data.count else { return .failure(CardError("只送出 \(n)/\(data.count) bytes")) }
        usleep(150_000)                     // 讓對方讀完再關（實測 SendMessage 也是送完就關）
        return .success(id)
    }
}
