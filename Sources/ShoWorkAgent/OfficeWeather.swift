import Foundation
import ShoWorkCore

/// 真實天氣（10-21，規範 §3.8.2）：Open-Meteo 每 10 分鐘抓一次勾選的地點（URLSession 背景、絕不卡主執行緒），
/// 每地各自失敗保留上次結果。畫面（雲、雨、颱風）只跟主天氣＝勾選的第一個；勾選的都在天氣列並排、附更新時間。
/// 地點預設只有台北（10-25 Kang：學弟 10-23 加的龜山、桃園機場天氣都一樣，拿掉）；每個人點天氣列自己搜尋、加入（最多 5 個）、移除、換主天氣。
/// 失敗（離線、Open-Meteo 掛了）：有舊資料就留著；從來沒抓到過顯示「—」。不另外重試，等下一輪 10 分鐘（不會重試風暴）。
/// 第一次用到 3D 辦公室（OfficeView 讀 shared）才開始抓；燈光選單裡的「真實天氣」關掉就停。
/// 測試視窗不連網：SHOWORK_OFFICE_WEATHER=clear|cloudy|overcast|rain|heavy|storm|typhoon 強制天氣（逗號分隔＝依序給清單的地點，
/// 少給的沿用最後一個），不設＝晴天；=live 才真的連網抓（驗收截圖用）
@MainActor
final class OfficeWeather: ObservableObject {
    static let shared = OfficeWeather()
    static let interval: TimeInterval = 600

    struct Report: Equatable {
        var now: WeatherNow
        /// 最近一次成功抓到的時間
        var at: Date
    }

    /// 各地最近一次成功抓到的觀測
    @Published private(set) var reports: [WeatherSite: Report] = [:]
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            if !BoardWindow.testMode { OfficePrefs().store.set(enabled, forKey: OfficePrefs.weatherKey) }
            enabled ? start() : stop()
        }
    }
    /// 地點清單（第一個是主天氣）
    @Published var sites: [WeatherSite] {
        didSet {
            guard sites != oldValue else { return }
            if !BoardWindow.testMode {
                OfficePrefs().store.set(WeatherSite.save(sites), forKey: OfficePrefs.weatherPlacesKey)
                OfficePrefs().store.removeObject(forKey: OfficePrefs.weatherSitesKey)
            }
            reports = reports.filter { sites.contains($0.key) }
            failed = failed.intersection(sites)
            if enabled, live { fetch() }       // 新加的地點馬上抓一次（已經在抓的不重複）
        }
    }
    /// 抓過但失敗、而且手上沒有資料的地點（天氣列顯示「—」）
    @Published private(set) var failed: Set<WeatherSite> = []
    var main: WeatherSite { sites.first ?? .taipei }
    private static let testValue = OfficeView.testEnv("SHOWORK_OFFICE_WEATHER")
    private let live = !BoardWindow.testMode || testValue == "live"
    private var timer: Timer?
    private var inFlight: Set<WeatherSite> = []

    private init() {
        enabled = BoardWindow.testMode ? true : (OfficePrefs().store.object(forKey: OfficePrefs.weatherKey) as? Bool ?? true)
        if BoardWindow.testMode {
            let names = OfficeView.testEnv("SHOWORK_OFFICE_WEATHER_SITES")?.split(separator: ",").map(String.init) ?? []
            let xs = names.compactMap { WeatherSite.presets[$0] }
            sites = xs.isEmpty ? WeatherSite.defaults : xs
        } else {
            let st = OfficePrefs().store
            sites = WeatherSite.load(st.data(forKey: OfficePrefs.weatherPlacesKey), legacy: st.stringArray(forKey: OfficePrefs.weatherSitesKey))
        }
        if Self.testValue == "fail" { failed = Set(sites) }       // 測試：從來沒抓到 ⇒「—」
        if !live, let names = Self.testValue?.split(separator: ",").map(String.init), !names.isEmpty {
            let t = Date()
            for (i, s) in sites.enumerated() {
                if let w = WeatherKind.preset(names[min(i, names.count - 1)]) { reports[s] = Report(now: w, at: t) }
            }
        }
        if enabled { start() }
    }

    /// 畫面用的天氣＝主天氣（關掉＝nil＝晴天）
    var current: WeatherNow? { enabled ? reports[main]?.now : nil }
    var look: WeatherLook { WeatherLook.of(current) }
    /// 天氣列：關掉就整列不顯示
    func report(_ s: WeatherSite) -> Report? { enabled ? reports[s] : nil }

    static func symbol(_ k: WeatherKind) -> String {
        switch k {
        case .clear: return "sun.max"
        case .cloudy: return "cloud.sun"
        case .overcast: return "cloud"
        case .lightRain: return "cloud.drizzle"
        case .heavyRain: return "cloud.heavyrain"
        case .thunder: return "cloud.bolt.rain"
        case .typhoon: return "wind"
        }
    }
    /// 選單裡的狀態
    var menuStatus: String {
        guard enabled else { return "真實天氣：關" }
        if !live { return reports.isEmpty ? "測試視窗不連網（晴）" : "測試：假天氣" }
        return reports[main].map { $0.now.summary(main) } ?? "\(main.title)天氣：讀取中（先當晴天）"
    }

    // MARK: 地名搜尋（點天氣列的地點面板用）

    @Published private(set) var results: [WeatherSite] = []
    @Published private(set) var searchNote: String?
    private var searchTask: Task<Void, Never>?

    /// 打字就呼叫：停 300 毫秒才真的查（隊長 Penny 10-25），新的一筆取消舊的；測試視窗不連網
    func search(_ q: String) {
        searchTask?.cancel()
        guard let url = Geocode.url(q) else { results = []; searchNote = q.trimmingCharacters(in: .whitespaces).isEmpty ? nil : "至少打 2 個字"; return }
        guard live else { results = Array(WeatherSite.presets.values).filter { $0.title.contains(q) }; searchNote = results.isEmpty ? "測試視窗不連網" : nil; return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            searchNote = "搜尋中⋯"
            var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 10)
            req.setValue("ShoWork42", forHTTPHeaderField: "User-Agent")
            let got = try? await URLSession.shared.data(for: req)
            guard !Task.isCancelled else { return }
            if let (d, r) = got, (r as? HTTPURLResponse)?.statusCode == 200 {
                results = Geocode.parse(d)
                searchNote = results.isEmpty ? "找不到這個地方" : nil
            } else { results = []; searchNote = "搜尋失敗（離線或服務沒回應），等一下再試" }
        }
    }

    private func start() {
        guard live, timer == nil else { return }
        fetch()
        let t = Timer(timeInterval: Self.interval, repeats: true) { _ in Task { @MainActor in OfficeWeather.shared.fetch() } }
        t.tolerance = 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func fetch() {
        for site in sites where !inFlight.contains(site) {
            inFlight.insert(site)
            var req = URLRequest(url: OpenMeteo.url(site), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("ShoWork42", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                let w = ok ? data.flatMap(OpenMeteo.parse) : nil      // 背景執行緒解析
                Task { @MainActor in
                    let me = OfficeWeather.shared
                    me.inFlight.remove(site)
                    if let w { me.reports[site] = Report(now: w, at: Date()); me.failed.remove(site) }   // 失敗：保留上次（更新時間也不動）
                    else if me.reports[site] == nil, me.sites.contains(site) { me.failed.insert(site) }
                }
            }.resume()
        }
    }
}
