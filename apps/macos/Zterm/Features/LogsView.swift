import SwiftUI

/// Riwayat sesi SSH: kapan, ke mana, berapa lama, dan hasilnya.
struct LogsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    @State private var confirmClear = false

    private var grouped: [(String, [SessionLog])] {
        let cal = Calendar.current
        let dict = Dictionary(grouping: model.logs) { cal.startOfDay(for: Date(ms: $0.startedAt)) }
        return dict.keys.sorted(by: >).map { day in
            let title = cal.isDateInToday(day) ? L("Hari ini")
                : cal.isDateInYesterday(day) ? L("Kemarin")
                : day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            return (title, dict[day]!)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: L("Logs"), subtitle: L("Riwayat sesi SSH di semua perangkat yang tersinkron")) {
                    Button(role: .destructive) { confirmClear = true } label: {
                        PhosphorLabel(text: L("Bersihkan"), icon: "trash", size: 12)
                    }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.logs.isEmpty)
                }
                if model.logs.isEmpty {
                    EmptyState(ph: "clock", title: L("Belum ada riwayat"), text: L("Setiap sesi SSH yang kamu buka akan tercatat di sini."))
                } else {
                    ForEach(grouped, id: \.0) { day, logs in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(day.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.1).foregroundStyle(.secondary)
                            VStack(spacing: 6) {
                                ForEach(Array(logs.enumerated()), id: \.element.id) { i, l in
                                    LogRow(log: l, hidden: hideAddresses).staggerIn(i, base: 0)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .confirmationDialog(L("Hapus semua riwayat sesi?"), isPresented: $confirmClear) {
            Button(L("Hapus semua"), role: .destructive) { model.clearLogs() }
        }
    }
}

struct LogRow: View {
    @Environment(AppModel.self) private var model
    let log: SessionLog
    let hidden: Bool

    private var host: Host? { model.host(id: log.hostId) }

    private var status: (String, Color) {
        guard log.endedAt != nil else {
            let live = model.sessions.contains { $0.host.id == log.hostId && $0.status != .connecting }
            return live ? (L("Berjalan"), Theme.green) : (L("Terputus"), .gray)
        }
        switch log.exitCode {
        case .some(0): return (L("Selesai"), Theme.accent)
        case .some(255): return (L("Gagal connect"), .orange)
        case .some(let c): return (L("Keluar ({})", c), .yellow)
        case .none: return (L("Ditutup"), .secondary)
        }
    }

    private var duration: String {
        let end = log.endedAt.map { Date(ms: $0) } ?? Date()
        let secs = max(0, end.timeIntervalSince(Date(ms: log.startedAt)))
        let f = DateComponentsFormatter()
        f.allowedUnits = secs >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: secs) ?? "-"
    }

    private var address: String {
        guard hidden, let at = log.address.firstIndex(of: "@") else { return log.address }
        return String(log.address[...at]) + "••••••••"
    }

    var body: some View {
        HoverCard(padding: 12) {
            HStack(spacing: 12) {
                Circle().fill(Color(hex: host?.color ?? "#94A3B8")).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.hostLabel).font(.system(size: 13, weight: .semibold))
                    Text(address).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Date(ms: log.startedAt).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(duration).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .trailing)
                Badge(text: status.0, color: status.1).frame(width: 100, alignment: .trailing)
                if let host {
                    IconButton(symbol: "bolt.fill", help: L("Connect lagi"), tint: Theme.accent) { model.connect([host.id]) }
                }
            }
        }
    }
}

extension Date {
    init(ms: Int64) { self.init(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}
