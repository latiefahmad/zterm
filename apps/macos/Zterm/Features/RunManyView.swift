import AppKit
import SwiftUI

// MARK: - Model

/// "Jalankan perintah di banyak server": satu perintah non-interaktif, paralel (maks. 8 sekaligus),
/// hasil (exit code, output, durasi) per server.
@MainActor
@Observable
final class RunManyModel: Identifiable {
    enum Status: Equatable {
        case waiting, running, ok, failed(UInt32?), timeout, error(String)
        var done: Bool { self != .waiting && self != .running }
        var success: Bool { self == .ok }
    }

    struct Row: Identifiable {
        let id: String
        var status: Status = .waiting
        var output = ""
        var durationMs: UInt64 = 0
        var truncated = false
    }

    let id = UUID()
    var command = ""
    var targets: Set<String>
    var timeout: UInt32 = 120
    var rows: [Row] = []
    var running = false
    var expanded: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    static let parallel = 8

    init(targets: Set<String>) { self.targets = targets }

    var okCount: Int { rows.filter { $0.status.success }.count }
    var failCount: Int { rows.filter { $0.status.done && !$0.status.success }.count }
    var pendingCount: Int { rows.filter { !$0.status.done }.count }

    /// Jalankan di semua target terpilih, atau hanya `only` (mis. ulang yang gagal).
    func run(_ app: AppModel, only: [String]? = nil) {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !running else { return }
        let ids = only ?? app.hosts.map(\.id).filter(targets.contains)
        guard !ids.isEmpty else { return }
        if only == nil {
            rows = ids.map { Row(id: $0) }
            expanded = []
        } else {
            for id in ids { if let i = rows.firstIndex(where: { $0.id == id }) { rows[i] = Row(id: id) } }
        }
        running = true
        let timeout = timeout
        let jobs = ids.map { ($0, app.sshTarget(forId: $0)) }
        task = Task { [weak self] in
            await withTaskGroup(of: (String, RemoteRun?, String?).self) { group in
                var queue = jobs[...]
                func launch(_ g: inout TaskGroup<(String, RemoteRun?, String?)>) -> String? {
                    guard let (id, target) = queue.popFirst() else { return nil }
                    g.addTask {
                        guard let target else { return (id, nil, L("Host tidak ditemukan")) }
                        do { return (id, try await runRemote(target: target, command: cmd, timeoutSecs: timeout), nil) }
                        catch { return (id, nil, error.ztermMessage) }
                    }
                    return id
                }
                for _ in 0..<Self.parallel {
                    if let id = launch(&group) { self?.update(id) { $0.status = .running } }
                }
                for await (id, result, error) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    self?.finish(id, result, error)
                    if let next = launch(&group) { self?.update(next) { $0.status = .running } }
                }
            }
            guard let self else { return }
            for i in rows.indices where !rows[i].status.done { rows[i].status = .error(L("Dibatalkan")) }
            withAnimation(.ztermSnappy) { running = false }
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: String, _ f: (inout Row) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.ztermSnappy) { f(&rows[i]) }
    }

    private func finish(_ id: String, _ r: RemoteRun?, _ error: String?) {
        update(id) { row in
            if let r {
                row.output = r.output
                row.durationMs = r.durationMs
                row.truncated = r.truncated
                row.status = r.timedOut ? .timeout : r.exitCode == 0 ? .ok : .failed(r.exitCode)
            } else {
                row.status = .error(error ?? L("Gagal"))
            }
        }
        // Yang gagal langsung dibuka agar output-nya terlihat
        if let row = rows.first(where: { $0.id == id }), !row.status.success { expanded.insert(id) }
    }

    /// Semua output, dipisah per server — untuk disalin.
    func report(_ app: AppModel) -> String {
        rows.map { row in
            let name = app.host(id: row.id)?.title ?? row.id
            return L("=== {} — {} ===\n{}", name, Self.label(row.status), row.output)
        }.joined(separator: "\n\n")
    }

    static func label(_ s: Status) -> String {
        switch s {
        case .waiting: L("Menunggu")
        case .running: L("Berjalan…")
        case .ok: L("Sukses")
        case .failed(let c): c.map { L("Gagal · exit {}", $0) } ?? L("Gagal")
        case .timeout: L("Timeout")
        case .error(let m): m
        }
    }
}

// MARK: - View

struct RunManyView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var run: RunManyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Jalankan perintah")).font(.title3.bold())
                    Text(L("Satu perintah di banyak server sekaligus — hasilnya per server")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            editor
            targets
            if !run.rows.isEmpty { results }
            footer
        }
        .padding(24)
        .frame(width: 820)
        .frame(minHeight: run.rows.isEmpty ? 0 : 640, alignment: .top)
        .animation(.zterm, value: run.rows.isEmpty)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("PERINTAH")).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                if !model.snippets.isEmpty {
                    Menu {
                        ForEach(model.snippets, id: \.id) { s in Button(s.label) { run.command = s.command } }
                    } label: { PhosphorLabel(sf: "curlybraces", text: L("Snippet"), size: 12) }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Picker(L("Batas waktu"), selection: $run.timeout) {
                    Text(L("30 detik")).tag(UInt32(30))
                    Text(L("2 menit")).tag(UInt32(120))
                    Text(L("10 menit")).tag(UInt32(600))
                    Text(L("30 menit")).tag(UInt32(1800))
                }
                .fixedSize()
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $run.command)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if run.command.isEmpty {
                    Text(L("mis. df -h /   ·   uptime   ·   apt list --upgradable 2>/dev/null | wc -l"))
                        .font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 72)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ink.opacity(0.08)))
            PhosphorLabel(sf: "info.circle", text: L("Berjalan tanpa terminal interaktif. Perintah yang menunggu input (mis. sudo dengan password) akan berhenti di batas waktu — pakai user root atau sudo -n."), size: 12)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var targets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("SERVER · {} DIPILIH", run.targets.count)).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Button(L("Semua")) { run.targets = Set(model.hosts.map(\.id)) }.buttonStyle(.borderless)
                Button(L("Hanya online")) {
                    run.targets = Set(model.dashboard.tiles.values.filter { $0.state == .online }.map(\.id))
                }
                .buttonStyle(.borderless)
                .disabled(model.dashboard.tiles.isEmpty)
                Button(L("Kosongkan")) { run.targets = [] }.buttonStyle(.borderless)
            }
            .font(.callout)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.hosts, id: \.id) { h in chip(h) }
                }
            }
            .frame(maxHeight: run.rows.isEmpty ? 190 : 76)
        }
        .disabled(run.running)
    }

    private func chip(_ h: Host) -> some View {
        let on = run.targets.contains(h.id)
        let tile = model.dashboard.tiles[h.id]
        return Button {
            if on { run.targets.remove(h.id) } else { run.targets.insert(h.id) }
        } label: {
            HStack(spacing: 7) {
                PhosphorIcon(sf: on ? "checkmark.circle.fill" : "circle", size: 14)
                    .foregroundStyle(on ? Theme.accent : .secondary)
                Circle().fill(Color(hex: h.color)).frame(width: 7, height: 7)
                Text(h.title).lineLimit(1)
                Spacer(minLength: 0)
                if tile?.state == .online { Circle().fill(Color(hex: "#4ADE80")).frame(width: 6, height: 6).help(L("Online")) }
                else if tile?.isOffline == true { Circle().fill(Color(hex: "#F0616D")).frame(width: 6, height: 6).help(L("Offline")) }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Theme.accent.opacity(0.12) : Theme.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? Theme.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text(L("HASIL")).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                summary("checkmark.circle.fill", run.okCount, L("sukses"), Color(hex: "#4ADE80"))
                summary("xmark.circle.fill", run.failCount, L("gagal"), Color(hex: "#F0616D"))
                if run.pendingCount > 0 { summary("clock", run.pendingCount, L("berjalan"), .secondary) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(run.report(model), forType: .string)
                    model.flash(L("Output semua server disalin"))
                } label: { PhosphorLabel(sf: "doc.on.doc", text: L("Salin semua"), size: 12) }
                .buttonStyle(.borderless)
                .disabled(run.running)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(run.rows) { row in ResultRow(run: run, row: row) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func summary(_ icon: String, _ n: Int, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            PhosphorIcon(sf: icon, size: 13).foregroundStyle(color)
            Text("\(n) \(text)").contentTransition(.numericText())
        }
        .font(.system(size: 12, weight: .medium))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("Tutup")) { run.cancel(); dismiss() }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            if run.running {
                Button(L("Batalkan")) { run.cancel() }.buttonStyle(SecondaryButtonStyle())
            } else if run.failCount > 0 {
                Button(L("Ulangi yang gagal")) {
                    run.run(model, only: run.rows.filter { $0.status.done && !$0.status.success }.map(\.id))
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button {
                run.run(model)
            } label: {
                HStack(spacing: 7) {
                    if run.running { ProgressView().controlSize(.small) } else { PhosphorIcon(sf: "play.fill", size: 13) }
                    Text(run.running ? L("Menjalankan…") : L("Jalankan di {} server", run.targets.count))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(run.running || run.targets.isEmpty || run.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct ResultRow: View {
    @Environment(AppModel.self) private var model
    let run: RunManyModel
    let row: RunManyModel.Row

    private var open: Bool { run.expanded.contains(row.id) }

    var body: some View {
        let host = model.host(id: row.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.ztermSnappy) {
                    if open { run.expanded.remove(row.id) } else { run.expanded.insert(row.id) }
                }
            } label: {
                HStack(spacing: 9) {
                    icon.frame(width: 16)
                    Circle().fill(Color(hex: host?.color ?? "#94A3B8")).frame(width: 7, height: 7)
                    Text(host?.title ?? row.id).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(RunManyModel.label(row.status)).font(.system(size: 11.5)).foregroundStyle(tint).lineLimit(1)
                    if !open, let last = row.output.split(whereSeparator: \.isNewline).last {
                        Text(last).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if row.status.done, row.durationMs > 0 {
                        Text(duration).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    PhosphorIcon(sf: "chevron.right", size: 10).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ScrollView {
                    Text(row.output.isEmpty ? (row.status.done ? L("(tidak ada output)") : "…") : row.output + (row.truncated ? L("\n… (output dipotong di 256 KB)") : ""))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var tint: Color {
        switch row.status {
        case .ok: Color(hex: "#4ADE80")
        case .failed, .error: Color(hex: "#F0616D")
        case .timeout: Color(hex: "#F2A65A")
        default: .secondary
        }
    }

    @ViewBuilder private var icon: some View {
        switch row.status {
        case .waiting: PhosphorIcon(sf: "clock", size: 14).foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .ok: PhosphorIcon(sf: "checkmark.circle.fill", size: 14).foregroundStyle(tint)
        case .timeout: PhosphorIcon(sf: "hourglass", size: 14).foregroundStyle(tint)
        default: PhosphorIcon(sf: "xmark.circle.fill", size: 14).foregroundStyle(tint)
        }
    }

    private var duration: String {
        row.durationMs < 1000 ? L("{} ms", row.durationMs) : String(format: L("%.1f dtk"), Double(row.durationMs) / 1000)
    }
}
