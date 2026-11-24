import AppKit
import SwiftUI

// MARK: - Model

/// Progress backup/restore (dipanggil dari thread core): jumlah byte yang sudah diproses.
final class BackupProgress: TransferProgress, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var last = Date.distantPast
    private let onUpdate: @Sendable (UInt64, UInt64) -> Void

    init(onUpdate: @escaping @Sendable (UInt64, UInt64) -> Void) { self.onUpdate = onUpdate }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    func onProgress(done: UInt64, total: UInt64, currentFile: String) {
        let now = Date()
        lock.lock()
        let push = now.timeIntervalSince(last) > 0.15 || (total > 0 && done == total)
        if push { last = now }
        lock.unlock()
        if push { onUpdate(done, total) }
    }

    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Jadwal backup otomatis per koneksi (tersimpan di Mac ini, bukan di vault).
struct BackupSchedule: Codable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case off, daily, weekly
        var id: String { rawValue }
        var title: String { switch self { case .off: L("Mati"); case .daily: L("Tiap hari"); case .weekly: L("Tiap minggu") } }
    }
    var frequency: Frequency = .off
    var hour = 2
    var keep = 7
    var drive = false
    var last: Date?
    var lastError: String?
}

/// Backup & restore database ke ~/Documents/Zterm Backups (opsional Google Drive), plus jadwal otomatis.
@MainActor
@Observable
final class BackupModel {
    struct Job: Equatable {
        var restore: Bool
        var bytes: UInt64 = 0
        var total: UInt64 = 0
        var stage = ""
    }

    struct Item: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let name: String
        let size: Int64
        let date: Date
    }

    var jobs: [String: Job] = [:]
    var schedules: [String: BackupSchedule] = [:]
    /// Diubah setiap ada file baru/dihapus agar daftar dimuat ulang.
    var revision = 0

    @ObservationIgnored private var progress: [String: BackupProgress] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?
    private static let key = "backup.schedules"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode([String: BackupSchedule].self, from: data) { schedules = s }
    }

    static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["ZTERM_BACKUP_DIR"] { return URL(fileURLWithPath: custom) }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return docs.appendingPathComponent("Zterm Backups")
    }

    static func folder(_ c: DbConnection) -> URL {
        let safe = c.title.map { $0.isLetter || $0.isNumber || "-_ ".contains($0) ? $0 : "_" }
        return root.appendingPathComponent(String(safe).trimmingCharacters(in: .whitespaces).isEmpty ? c.id : String(safe))
    }

    func schedule(_ id: String) -> BackupSchedule { schedules[id] ?? BackupSchedule() }

    func setSchedule(_ id: String, _ s: BackupSchedule) {
        schedules[id] = s
        if let data = try? JSONEncoder().encode(schedules) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func items(_ c: DbConnection) -> [Item] {
        _ = revision
        let dir = Self.folder(c)
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(".gz") }.compactMap { u in
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return Item(path: u.path, name: u.lastPathComponent, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast)
        }.sorted { $0.date > $1.date }
    }

    func cancel(_ id: String) { progress[id]?.cancel() }

    /// Backup sekarang. Mengembalikan pesan untuk ditampilkan (atau nil bila sukses tanpa pesan khusus).
    @discardableResult
    func backup(_ c: DbConnection, app: AppModel, scheduled: Bool = false) async -> Bool {
        guard jobs[c.id] == nil else { return false }
        let stamp = Self.stampFormatter.string(from: Date())
        let db = c.database.isEmpty ? "" : "_" + c.database.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "_" }.reduce("") { $0 + String($1) }
        let dest = Self.folder(c).appendingPathComponent("\(stamp)\(db)\(backupExtension(engine: c.engine))")
        let p = BackupProgress { [weak self] done, total in
            Task { @MainActor in self?.jobs[c.id]?.bytes = done; self?.jobs[c.id]?.total = total }
        }
        progress[c.id] = p
        jobs[c.id] = Job(restore: false, stage: L("Membuat backup…"))
        defer { jobs[c.id] = nil; progress[c.id] = nil; revision += 1 }
        var s = schedule(c.id)
        do {
            let r = try await backupDatabase(conn: c, ssh: app.sshTarget(forId: c.sshHostId), destPath: dest.path,
                                             toolDirs: [app.stack.rootPath], progress: p)
            prune(c, keep: s.keep)
            var note = L("Backup {} selesai · {}", c.title, ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file))
            if s.drive {
                jobs[c.id]?.stage = L("Mengunggah ke Google Drive…")
                jobs[c.id]?.bytes = 0
                do {
                    _ = try await driveUploadBackup(token: try await app.driveToken(), path: r.path, progress: p)
                    note += L(" · tersimpan juga di Google Drive")
                } catch {
                    note += L(" · gagal unggah ke Drive: {}", error.ztermMessage)
                }
            }
            s.last = Date(); s.lastError = nil
            setSchedule(c.id, s)
            app.flash(note)
            return true
        } catch CoreError.Cancelled {
            app.flash(L("Backup dibatalkan"))
        } catch {
            s.lastError = error.ztermMessage
            if scheduled { s.last = Date() }
            setSchedule(c.id, s)
            app.flash(L("Backup {} gagal: {}", c.title, error.ztermMessage))
            if scheduled { Notifier.shared.send(title: L("Backup {} gagal", c.title), body: error.ztermMessage, key: "backup:\(c.id)") }
        }
        return false
    }

    func restore(_ c: DbConnection, item: Item, app: AppModel) async {
        guard jobs[c.id] == nil else { return }
        let p = BackupProgress { [weak self] done, total in
            Task { @MainActor in self?.jobs[c.id]?.bytes = done; self?.jobs[c.id]?.total = total }
        }
        progress[c.id] = p
        jobs[c.id] = Job(restore: true, stage: L("Memulihkan {}…", item.name))
        defer { jobs[c.id] = nil; progress[c.id] = nil }
        do {
            try await restoreDatabase(conn: c, ssh: app.sshTarget(forId: c.sshHostId), srcPath: item.path, toolDirs: [app.stack.rootPath], progress: p)
            app.flash(L("{} dipulihkan dari {}", c.title, item.name))
        } catch CoreError.Cancelled {
            app.flash(L("Restore dibatalkan"))
        } catch {
            app.flash(L("Restore gagal: {}", error.ztermMessage))
        }
    }

    func delete(_ item: Item) {
        try? FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
        revision += 1
    }

    /// Simpan hanya `keep` backup terbaru (yang lama dipindah ke Trash).
    private func prune(_ c: DbConnection, keep: Int) {
        guard keep > 0 else { return }
        for old in items(c).dropFirst(keep) {
            try? FileManager.default.trashItem(at: URL(fileURLWithPath: old.path), resultingItemURL: nil)
        }
    }

    // MARK: Jadwal

    func startTimer(app: AppModel) {
        timer?.cancel()
        timer = Task { [weak self, weak app] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let app, !Task.isCancelled else { return }
                await self.runDue(app)
            }
        }
    }

    func stopTimer() { timer?.cancel(); timer = nil }

    /// Jalankan backup yang jadwalnya sudah lewat (hanya selama app terbuka & vault tidak dikunci).
    func runDue(_ app: AppModel) async {
        for c in app.databases {
            let s = schedule(c.id)
            guard s.frequency != .off, backupSupported(engine: c.engine), jobs[c.id] == nil, Self.isDue(s, now: Date()) else { continue }
            await backup(c, app: app, scheduled: true)
        }
    }

    static func isDue(_ s: BackupSchedule, now: Date) -> Bool {
        let cal = Calendar.current
        guard let todayAt = cal.date(bySettingHour: s.hour, minute: 0, second: 0, of: now) else { return false }
        let slot = now >= todayAt ? todayAt : cal.date(byAdding: .day, value: -1, to: todayAt)!
        let period: TimeInterval = s.frequency == .weekly ? 7 * 86_400 : 86_400
        guard let last = s.last else { return true }
        return last < slot && now.timeIntervalSince(last) >= period - 3_600
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Sheet

struct BackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let db: DbConnection
    @State private var restoring: BackupModel.Item?

    var body: some View {
        let backups = model.backups
        let job = backups.jobs[db.id]
        let items = backups.items(db)
        var sched = backups.schedule(db.id)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                EngineBadge(preset: DbPreset.find(db), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Backup · {}", db.title)).font(.title3.bold())
                    Text(db.sshHostId != nil ? L("Dump dijalankan di server lewat SSH, hasilnya disimpan di Mac ini") : L("Memakai alat dump di Mac ini (termasuk komponen Server Lokal)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Backup sekarang
            HStack(spacing: 12) {
                if let job {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.stage).font(.callout.weight(.medium))
                        Text(progressText(job)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Batalkan")) { backups.cancel(db.id) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Button { Task { await backups.backup(db, app: model) } } label: { Label(L("Backup sekarang"), systemImage: "externaldrive.badge.plus") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { NSWorkspace.shared.open(BackupModel.folder(db).deletingLastPathComponent().appendingPathComponent(BackupModel.folder(db).lastPathComponent)) } label: {
                        Label(L("Buka folder"), systemImage: "folder")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(items.isEmpty)
                    Spacer()
                }
            }
            .padding(12)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

            // Jadwal
            VStack(alignment: .leading, spacing: 10) {
                Text(L("JADWAL OTOMATIS")).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Picker("", selection: Binding(get: { sched.frequency }, set: { sched.frequency = $0; backups.setSchedule(db.id, sched) })) {
                        ForEach(BackupSchedule.Frequency.allCases) { f in Text(f.title).tag(f) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if sched.frequency != .off {
                        Picker(L("pukul"), selection: Binding(get: { sched.hour }, set: { sched.hour = $0; backups.setSchedule(db.id, sched) })) {
                            ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d.00", h)).tag(h) }
                        }
                        .fixedSize()
                        Stepper(L("Simpan {} terakhir", sched.keep), value: Binding(get: { sched.keep }, set: { sched.keep = $0; backups.setSchedule(db.id, sched) }), in: 1...60)
                            .fixedSize()
                    }
                }
                Toggle(isOn: Binding(get: { sched.drive }, set: { sched.drive = $0; backups.setSchedule(db.id, sched) })) {
                    Text(L("Unggah juga ke Google Drive (folder “Zterm Backups”)"))
                }
                .disabled(!model.teamReady)
                .help(model.teamReady ? "" : L("Masuk dengan Google dan izinkan akses Google Drive di menu Akun"))
                if sched.frequency != .off {
                    Text(L("Berjalan selama Zterm terbuka. Bila Mac mati saat jadwal tiba, backup dibuat begitu app dibuka lagi."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let e = sched.lastError {
                    Label(L("Backup terakhir gagal: {}", e), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Color(hex: "#F0616D"))
                } else if let last = sched.last {
                    Text(L("Backup terakhir: {}", last.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary)
                }
            }

            // Daftar backup
            VStack(alignment: .leading, spacing: 8) {
                Text(L("BACKUP TERSIMPAN · {}", items.count)).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                if items.isEmpty {
                    Text(L("Belum ada backup.")).font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(items) { item in row(item, busy: job != nil) }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }

            HStack {
                Spacer()
                Button(L("Selesai")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 600)
        .confirmationDialog(L("Pulihkan {} dari backup ini?", db.title), isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            if let item = restoring {
                Button(L("Pulihkan (timpa data)"), role: .destructive) { Task { await backups.restore(db, item: item, app: model) } }
            }
        } message: {
            if let item = restoring {
                Text(L("{}\n\nTabel di database akan dihapus & dibuat ulang sesuai isi backup. Data yang belum ada di backup akan hilang. Sebaiknya buat backup baru dulu.", item.name))
            }
        }
    }

    private func row(_ item: BackupModel.Item, busy: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12.5, weight: .semibold))
                Text(item.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(L("Pulihkan")) { restoring = item }.buttonStyle(SecondaryButtonStyle()).disabled(busy)
            IconButton(symbol: "magnifyingglass", help: L("Tampilkan di Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            IconButton(symbol: "trash", help: L("Pindahkan ke Trash"), tint: Color(hex: "#F0616D")) { model.backups.delete(item) }
        }
        .padding(10)
        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func progressText(_ j: BackupModel.Job) -> String {
        let done = ByteCountFormatter.string(fromByteCount: Int64(j.bytes), countStyle: .file)
        if j.total > 0 { return "\(done) / \(ByteCountFormatter.string(fromByteCount: Int64(j.total), countStyle: .file))" }
        return j.restore ? L("{} dikirim", done) : L("{} data", done)
    }
}
