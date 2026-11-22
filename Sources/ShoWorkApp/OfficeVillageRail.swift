import SwiftUI
import ShoWorkCore

// 小島的左側索引列（11-12）：上面「地點」、下面「島民」。點地點＝鏡頭飛過去（再點一次回到全島）；點島民＝鏡頭飛到他、右邊開他的對話
// （等你回答的另外開回答卡，跟點 3D 角色同一條路）。離線的人點了飛到他家。

struct VillageRail: View {
    let plan: VillagePlan
    let selected: String?
    var alerts: [VillageSign] = []
    let onPlace: (String) -> Void
    let onPerson: (String) -> Void
    @ObservedObject private var school = SchoolStore.shared

    static let red = Color(red: 0.94, green: 0.27, blue: 0.27), orange = Color(red: 0.98, green: 0.45, blue: 0.09)
    static let green = Color(red: 0.13, green: 0.77, blue: 0.37), purple = Color(red: 0.65, green: 0.55, blue: 0.98)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header("地點")
                    place("place:shop", "house", plan.shopName, sub: count(.shop) == "沒有人" ? "隊長" : "隊長＋" + count(.shop))
                    place("place:company", "building", "Okle42 小屋", sub: count(.company))
                    ForEach(Array(plan.stalls.enumerated()), id: \.offset) { i, s in
                        place("place:stall:\(i)", "storefront", s, sub: "小攤")
                    }
                    place("place:school", "graduationcap", "學校", sub: school.state.summary)
                    place("place:campfire", "flame", "營火", sub: plazaCount)
                    place("place:facility", "wind", "風車・水塔・海・熱氣球・小棚子", sub: alerts.isEmpty ? "一切正常" : alerts.map(\.text).joined(separator: "、"),
                          alert: !alerts.isEmpty)
                    header("島民 \(plan.residents.filter(\.online).count)")
                    ForEach(people, id: \.id) { r in person(r) }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 等你的在最上面，其次工作中、做完、休息，離線最後
    private var people: [VillageResident] {
        func rank(_ r: VillageResident) -> Int {
            guard r.online else { return 9 }
            if r.needsAnswer { return 0 }
            switch r.mood { case .stuck: return 1; case .working: return 2; case .finished: return 3; default: return 4 }
        }
        return plan.residents.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }

    private func count(_ z: VillageZone) -> String {
        let n = plan.residents.filter { $0.zone == z && $0.online }.count
        return n == 0 ? "沒有人" : "\(n) 位島民"
    }
    private var plazaCount: String {
        let n = plan.residents.filter { $0.spot == .plaza }.count
        return n == 0 ? "沒有人" : "\(n) 位圍著營火"
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 2)
    }

    private func place(_ id: String, _ icon: String, _ title: String, sub: String, alert: Bool = false) -> some View {
        Button { onPlace(id) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(alert ? Self.red : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(sub).font(.system(size: 12)).foregroundStyle(alert ? Self.red : .secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected == id ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("鏡頭飛過去；再點一次回到全島")
    }

    private func where_(_ r: VillageResident) -> String {
        guard r.online else { return "回家了（離線）" }
        if r.zone == .townhall { return "在\(plan.shopName)門口（隊長）" }
        let at: String = switch r.zone {
        case .shop: plan.shopName
        case .company: "Okle42 小屋"
        case .personal: r.stall.flatMap { $0 < plan.stalls.count ? plan.stalls[$0] + " 小攤" : nil } ?? "小攤"
        case .townhall: plan.shopName
        }
        if r.needsAnswer { return "等你回答・\(at)" }
        switch r.mood {
        case .working: return "在\(at)忙"
        case .stuck: return "卡住了・\(at)"
        case .finished: return "做完了，在營火旁等你看"
        case .asleep: return "在營火旁打瞌睡"
        default: return "在營火旁休息"
        }
    }

    private func dot(_ r: VillageResident) -> Color {
        guard r.online else { return Color.gray.opacity(0.4) }
        if r.needsAnswer { return Self.red }
        switch r.mood { case .stuck: return Self.orange; case .working: return Self.purple; case .finished: return Self.green; default: return Color.gray.opacity(0.7) }
    }

    private func person(_ r: VillageResident) -> some View {
        Button { r.online ? onPerson(r.id) : onPlace(r.home.map { "place:home:\($0)" } ?? "place:plaza") } label: {
            HStack(spacing: 8) {
                Circle().fill(dot(r)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(r.pet ? (VillageStore.config?.petTitle(r.name) ?? r.name) : r.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if r.needsAnswer { Text("！").font(.system(size: 13, weight: .heavy)).foregroundStyle(Self.red) }
                        if r.zone == .townhall { Image(systemName: "crown.fill").font(.system(size: 10)).foregroundStyle(.yellow) }
                    }
                    Text(where_(r)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 40)
            .opacity(r.online ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(r.online ? "鏡頭飛到他、右邊看他的對話" : "鏡頭飛到他家")
    }
}
