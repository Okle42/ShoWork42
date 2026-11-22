import Foundation
import ShoWorkCore

// 科技大樓的資料接線（10-20，第 2 棒）：樓層號名冊存檔、7 天用量、AI 選主題（claude -p haiku）、閒晃排程。
// 全部掛在看板既有的刷新上（FSEvents＋15 秒保底），不新增 timer。只有正式 agent 會寫檔、會呼叫 claude；
// 測試視窗（--board-window）只讀現有的名冊／主題，在記憶體裡算。

enum TowerPaths {
    /// board/tower.json：樓層號名冊
    static var registry: URL { BoardPaths.dir.appendingPathComponent("tower.json") }
    /// AI 選主題的工作資料夾（空的：避免載入專案的 CLAUDE.md；在 BoardWatcher 監看範圍外）
    static var decorCwd: URL { Paths.supportDir.appendingPathComponent("decor-cwd", isDirectory: true) }
}

/// AI 選主題的 claude 呼叫（規範 §5.4；10-20 實測 claude 2.1.303 的旗標）：
///   --tools ""                 不給任何工具（不讀檔、不跑指令）
///   --strict-mcp-config        不載入 MCP 伺服器（省 token、省啟動時間）
///   --no-session-persistence   不寫對話紀錄（~/.claude/projects 底下不會多一個檔，看板的 FSEvents 也不會被叫醒）
///   --system-prompt            換掉預設的長系統提示詞（分類題用不到）
///   --max-turns 1、--model haiku、--output-format json（拿 result 與 total_cost_usd）
///   SHOWORK_REVIEWER=1         showork hook 早退（不發光、不上看板）；cwd 是空資料夾
enum DecorRunner {
    static let model = "haiku"
    static func args() -> [String] {
        ["-p", "--model", model, "--output-format", "json", "--max-turns", "1", "--tools", "", "--strict-mcp-config",
         "--no-session-persistence", "--system-prompt", DecorPrompt.system]
    }
    static let real: ThemePicker.Runner = { prompt in
        guard let claude = Tools.claude() else { return (-1, "", "找不到 claude 指令") }
        try? FileManager.default.createDirectory(at: TowerPaths.decorCwd, withIntermediateDirectories: true)
        let r = Tools.run(claude, args(), cwd: TowerPaths.decorCwd.path, env: ["SHOWORK_REVIEWER": "1"], stdin: prompt, timeout: 60)
        return (r.code, r.out, r.err)
    }
    /// 不呼叫 AI 的假 runner（--decor-pick 沒帶 --real 時用）：固定回一個合法結果
    static let fake: ThemePicker.Runner = { _ in
        (0, ##"{"type":"result","is_error":false,"result":"{\"theme\":\"monitor\",\"accentColor\":\"#5B8DB8\",\"props\":[\"console\",\"wall_clock\"],\"reason\":\"假 runner\"}","total_cost_usd":0}"##, "")
    }
}

/// 樓層主題的看板端：決定什麼時候叫 ThemePicker、收集線索（卡片＋transcript 尾端＋README）
@MainActor
final class TowerDecor {
    static let shared = TowerDecor()
    /// 只有正式 agent 會呼叫 AI、會寫快取；測試視窗只讀
    private(set) lazy var picker: ThemePicker = ThemePicker(dir: BoardPaths.dir, model: DecorRunner.model, runner: DecorRunner.real)
    private var prevColumn: [String: BoardColumn] = [:]
    private var readmeAsked = Set<String>()

    /// 看板設定「AI 裝潢」（office.decorAI，預設開；關掉只用本地評分）
    static let enabledKey = "office.decorAI"
    var enabled: Bool {
        get { UserDefaults(suiteName: OfficePrefs.suite)?.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults(suiteName: OfficePrefs.suite)?.set(newValue, forKey: Self.enabledKey) }
    }
    var official: Bool { Engine.current != nil }

    /// 每次刷新叫一次：找出「一輪工作結束」的專案（卡片從進行中／卡住變成待審／完成／待辦），交給 picker 判斷
    func consider(cards: [BoardCard], tower: TowerPlan) {
        var ended = Set<String>()
        for c in cards where !c.id.contains("#") {
            if let p = prevColumn[c.id], [.active, .stuck].contains(p), [.review, .done, .todo].contains(c.column) {
                ended.insert(c.project.lowercased())
            }
        }
        prevColumn = Dictionary(cards.filter { !$0.id.contains("#") }.map { ($0.id, $0.column) }, uniquingKeysWith: { a, _ in a })
        guard official else { return }
        for f in tower.projectFloors {
            guard let name = f.project else { continue }
            let mine = cards.filter { $0.project.caseInsensitiveCompare(name) == .orderedSame && !$0.id.contains("#") }
            start(name, cards: mine, turnEnded: ended.contains(name.lowercased()), force: false)
        }
    }

    /// 你按的「重新裝潢」：跳過「工作內容有沒有變」與同專案 6 小時，但總次數／成本上限、同時一個照樣擋
    @discardableResult
    func redecorate(_ project: String, cards: [BoardCard]) -> String {
        guard official else { return "測試視窗不呼叫 AI" }
        let mine = cards.filter { $0.project.caseInsensitiveCompare(project) == .orderedSame && !$0.id.contains("#") }
        let now = Date()
        if let why = DecorPolicy.blocked(project: project, ledger: picker.ledgerSnapshot, running: picker.runningProject != nil,
                                         enabled: enabled, force: true, limits: picker.limits, now: now) { return "暫時不能重新裝潢：\(why)" }
        return start(project, cards: mine, turnEnded: true, force: true) ? "已請 AI 重新裝潢「\(project)」" : "暫時不能重新裝潢"
    }

    @discardableResult
    private func start(_ project: String, cards: [BoardCard], turnEnded: Bool, force: Bool) -> Bool {
        let first = picker.cached(project) == nil || picker.cached(project)?.source != "ai"
        let wantReadme = first && !readmeAsked.contains(project.lowercased())
        let snap = cards
        let started = picker.consider(project, turnEnded: turnEnded, enabled: enabled, force: force,
                                      input: { TowerDecor.gather(project, cards: snap, readme: wantReadme) },
                                      changed: { v in
                                          Log.note("DECOR \(project) → \(v.theme.rawValue) \(v.source) \(v.reason)")
                                          DispatchQueue.main.async { MainActor.assumeIsolated { BoardModel.shared.decorChanged() } }
                                      },
                                      finished: { d in
                                          if case .keep(let why) = d, why.hasPrefix("AI 失敗") { Log.note("DECOR \(project) \(why)") }
                                      })
        if started && wantReadme { readmeAsked.insert(project.lowercased()) }
        return started
    }

    /// 專案身分（專案名＋README 標題與第一段）：每個專案只讀一次 README（4KB），之後用記憶體裡的
    private var identities: [String: WorkSignature] = [:]
    func identity(_ project: String, cards: [BoardCard]) -> WorkSignature {
        let k = project.lowercased()
        if let s = identities[k] { return s }
        let readme = Self.root(project, cards: cards).flatMap(Self.readmeHead)
        let s = WorkSignature.make(DecorInput(project: project, readme: readme))
        identities[k] = s
        return s
    }

    /// 收集線索（背景佇列）：卡片標題、自報摘要／正在做、AI 最後一句；每個 session 的 transcript 尾端 200KB；README 前 600 字
    nonisolated static func gather(_ project: String, cards: [BoardCard], readme: Bool) -> DecorInput {
        var inp = DecorInput(project: project)
        for c in cards {
            inp.notes.append(c.title)
            if let s = c.report?.summary { inp.notes.append(s) }
            if let d = c.report?.doing { inp.notes.append(d) }
            if let d = c.detail { inp.notes.append(String(d.prefix(200))) }
            let x = DecorInput.extract(tail: tail(c))
            inp.prompts += x.prompts.suffix(3); inp.paths += x.paths; inp.commands += x.commands
        }
        if readme, let root = root(project, cards: cards) { inp.readme = readmeHead(root) }
        return inp
    }

    /// 對話紀錄尾端 200KB（同審核員）
    nonisolated static func tail(_ c: BoardCard) -> Data {
        let sess = FileManager.default.contents(atPath: "\(BoardPaths.claude)/sessions/\(c.pid).json").flatMap(SessionRecord.decode)
        let slug = SessionRecord(pid: c.pid, sessionId: c.sessionId, cwd: sess?.cwd ?? c.cwd ?? BoardPaths.home).projectSlug
        guard let h = FileHandle(forReadingAtPath: "\(BoardPaths.claude)/projects/\(slug)/\(c.sessionId).jsonl") else { return Data() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
        return h.readDataToEndOfFile()
    }

    /// 專案資料夾：~/github-repos/<名>，不然從卡片的 cwd 往上找 .git
    nonisolated static func root(_ project: String, cards: [BoardCard]) -> String? {
        let fm = FileManager.default
        let r = BoardPaths.repos + "/" + project
        if fm.fileExists(atPath: r + "/.git") { return r }
        for c in cards {
            var p = c.cwd ?? ""
            while p.count > 1 {
                if fm.fileExists(atPath: p + "/.git") { return p }
                p = (p as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    nonisolated static func readmeHead(_ root: String) -> String? {
        for n in ["README.md", "README.zh-TW.md", "README", "readme.md"] {
            if let h = FileHandle(forReadingAtPath: root + "/" + n) {
                defer { try? h.close() }
                let d = h.readData(ofLength: 4096)
                // 10-20 §4.3：先去掉徽章／圖片／程式碼再取前 600 字（不然前 600 字常常一半是徽章）
                return String(DecorInput.cleanReadme(String(decoding: d, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            }
        }
        return nil
    }
}

/// 樓層號名冊＋7 天用量
enum TowerStore {
    static func load() -> TowerRegistry {
        FileManager.default.contents(atPath: TowerPaths.registry.path).flatMap(TowerRegistry.decode) ?? TowerRegistry()
    }
    static func save(_ r: TowerRegistry) {
        try? FileManager.default.createDirectory(at: BoardPaths.dir, withIntermediateDirectories: true)
        if let d = r.encoded() { try? d.write(to: TowerPaths.registry, options: .atomic) }
    }

    /// 最近 7 天用量（MB）：只在有新專案要發號碼時才算（第一次排名、之後偶爾一個新專案）
    static func usage(departments: [OfficeDepartment], cards: [BoardCard]) -> [String: Double] {
        var paths: [String: [String]] = [:]
        for d in departments {
            paths[d.name, default: []].append(BoardPaths.repos + "/" + d.name)
            if let r = TowerDecor.root(d.name, cards: cards.filter { $0.project == d.name }), r != BoardPaths.repos + "/" + d.name {
                paths[d.name, default: []].append(r)
            }
        }
        return ProjectUsage.scan(projectsDir: BoardPaths.claude + "/projects", projects: paths, now: Date())
    }

    /// 測試用：SHOWORK_OFFICE_WANDER=off|instant（截圖要穩定）；不設＝animate
    static var wanderMode: WanderMode {
        ProcessInfo.processInfo.environment["SHOWORK_OFFICE_WANDER"].flatMap(WanderMode.init(rawValue:)) ?? .animate
    }

    /// 測試用：SHOWORK_OFFICE_THEME=<專案>:<主題>[,<專案>:<主題>…] 強制主題（不寫檔）
    static func themeOverrides() -> [String: FloorDecor] {
        guard let s = ProcessInfo.processInfo.environment["SHOWORK_OFFICE_THEME"] else { return [:] }
        var out: [String: FloorDecor] = [:]
        for pair in s.split(separator: ",") {
            let kv = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let t = TowerTheme(rawValue: kv[1]) else { continue }
            out[kv[0].lowercased()] = FloorDecor(theme: t, accentColor: t.accent, props: Array(t.optionalProps.prefix(2)),
                                                 reason: "測試強制", source: "test", decidedAt: Date())
        }
        return out
    }

    /// 卡片 → 閒晃的角色（同層依卡片 id 排座位，跟規範 §2.0 一致；沒有樓層的人不算）
    static func people(_ cards: [BoardCard], tower: TowerPlan) -> [WanderPerson] {
        var byFloor: [String: [BoardCard]] = [:]
        for c in cards where !c.id.contains("#") { byFloor[TowerFloor.projectId(c.project), default: []].append(c) }
        var out: [WanderPerson] = []
        for (fid, cs) in byFloor where tower.floor(id: fid) != nil {
            let sorted = cs.sorted { $0.id < $1.id }
            for (i, c) in sorted.enumerated() {
                out.append(WanderPerson(sid: c.id, floor: fid, mood: Mood.of(c), seat: i, seats: sorted.count))
            }
        }
        return out.sorted { $0.sid < $1.sid }
    }
}
