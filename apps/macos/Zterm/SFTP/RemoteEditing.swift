import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model: editor bawaan & "Buka dengan" aplikasi lain

/// File server yang sedang dibuka di editor teks bawaan.
@MainActor
@Observable
final class RemoteEditorDoc: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    var text: String
    var original: String
    /// mtime server saat dibuka / terakhir disimpan (untuk deteksi bentrok).
    var remoteModified: Int64
    var saving = false
    var conflict = false
    var error: String?
    var dirty: Bool { text != original }
    var lineCount: Int {
        let n = text.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
        return text.hasSuffix("\n") ? n - 1 : n
    }

    init(path: String, name: String, text: String, modified: Int64) {
        self.path = path
        self.name = name
        self.text = text
        self.original = text
        self.remoteModified = modified
    }
}

/// File server yang dibuka di aplikasi lain; perubahan lokal diunggah balik otomatis.
@MainActor
@Observable
final class WatchedFile: Identifiable {
    let id = UUID()
    let remotePath: String
    let localURL: URL
    let appName: String
    var lastModified: Date?
    var uploading = false
    var lastUpload: Date?

    init(remotePath: String, localURL: URL, appName: String) {
        self.remotePath = remotePath
        self.localURL = localURL
        self.appName = appName
        lastModified = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

enum RemoteFiles {
    /// Batas ukuran file untuk editor bawaan.
    static let editorLimit: UInt64 = 5 * 1024 * 1024

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "cfg", "config", "env", "log", "properties",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "py", "rb", "php", "pl", "lua", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "vue", "svelte", "go", "rs", "java", "kt", "kts", "swift", "c", "h", "cc", "cpp", "hpp", "cs", "scala", "dart", "r",
        "html", "htm", "css", "scss", "sass", "less", "xml", "svg", "sql", "csv", "tsv", "service", "socket", "timer", "conf.d",
        "gradle", "lock", "gitignore", "dockerignore", "editorconfig", "htaccess", "pem", "pub", "crt", "csr", "key", "tf", "hcl",
        "graphql", "proto", "twig", "blade", "erb", "ejs", "mustache", "tpl", "rst", "tex", "srt", "vtt",
    ]
    private static let textNames: Set<String> = ["dockerfile", "makefile", "procfile", "vagrantfile", "gemfile", "rakefile", "license", "readme", "authorized_keys", "known_hosts", "crontab", "hosts", "fstab"]

    /// File yang wajar dibuka di editor teks (berdasarkan nama & ukuran).
    static func isTextLike(_ item: FileItem) -> Bool {
        guard !item.isDir, item.size <= editorLimit else { return false }
        let name = item.name.lowercased()
        let ext = (name as NSString).pathExtension
        if textExtensions.contains(ext) || textNames.contains(name) { return true }
        // Dotfile (.bashrc, .env.production) atau tanpa ekstensi yang kecil → kemungkinan teks
        if name.hasPrefix(".") || ext.isEmpty { return item.size <= 1024 * 1024 }
        return false
    }

    /// Aplikasi di Mac yang bisa membuka tipe file ini (aplikasi bawaan dulu).
    static func apps(for name: String) -> [URL] {
        let probe = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        var list = NSWorkspace.shared.urlsForApplications(toOpen: probe)
        let ext = (name as NSString).pathExtension
        if list.isEmpty, let type = UTType(filenameExtension: ext) ?? UTType("public.plain-text") {
            list = NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
        // Selalu tawarkan editor teks umum untuk file teks
        if let text = UTType("public.plain-text") {
            for u in NSWorkspace.shared.urlsForApplications(toOpen: text) where !list.contains(u) { list.append(u) }
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.lastPathComponent).inserted }.prefix(12).map { $0 }
    }

    static func appName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Tampilan editor

struct RemoteEditorView: View {
    @Environment(AppModel.self) private var model
    @Bindable var doc: RemoteEditorDoc
    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                PhosphorIcon(sf: fileIcon(doc.name), size: 16).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(doc.name).font(.system(size: 14, weight: .semibold))
                        if doc.dirty { Circle().fill(Color.orange).frame(width: 7, height: 7).help(L("Belum disimpan")) }
                    }
                    Text(doc.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    ForEach(RemoteFiles.apps(for: doc.name), id: \.self) { app in
                        Button(RemoteFiles.appName(app)) { openWith(app) }
                    }
                } label: { PhosphorLabel(sf: "arrow.up.forward.app", text: L("Buka dengan"), size: 12) }
                .menuStyle(.borderlessButton).fixedSize()
                Button { Task { await model.sftp.saveEditor(doc) } } label: {
                    HStack(spacing: 6) {
                        if doc.saving { ProgressView().controlSize(.small) } else { PhosphorIcon(sf: "arrow.up.doc", size: 13) }
                        Text(L("Simpan"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!doc.dirty || doc.saving)
                IconButton(symbol: "xmark", help: L("Tutup (⌘W)")) { close() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let e = doc.error {
                PhosphorLabel(sf: "exclamationmark.triangle.fill", text: e, size: 12)
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(Color.orange.opacity(0.08))
            }
            CodeTextView(text: $doc.text)
            Divider()
            HStack(spacing: 14) {
                Text(L("{} baris", doc.lineCount)).monospacedDigit()
                Text("UTF-8")
                Text(model.sftp.host.map { L("SFTP · {}", $0.title) } ?? "SFTP")
                Spacer()
                Text(L("⌘S simpan · ⌘F cari · ⌘W tutup"))
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
        }
        .frame(minWidth: 860, idealWidth: 1040, minHeight: 560, idealHeight: 720)
        .background(Theme.bg)
        .confirmationDialog(L("Simpan perubahan di {}?", doc.name), isPresented: $confirmClose) {
            Button(L("Simpan & tutup")) { Task { if await model.sftp.saveEditor(doc) { model.sftp.editor = nil } } }
            Button(L("Buang perubahan"), role: .destructive) { model.sftp.editor = nil }
            Button(L("Batal"), role: .cancel) {}
        } message: { Text(L("Perubahan belum disimpan ke server.")) }
        .confirmationDialog(L("File di server sudah berubah"), isPresented: $doc.conflict) {
            Button(L("Timpa dengan versi saya"), role: .destructive) { Task { await model.sftp.saveEditor(doc, force: true) } }
            Button(L("Batal"), role: .cancel) {}
        } message: { Text(L("Seseorang (atau proses lain) mengubah {} setelah kamu membukanya. Menyimpan akan menimpa perubahan itu.", doc.name)) }
    }

    private func close() {
        if doc.dirty { confirmClose = true } else { model.sftp.editor = nil }
    }

    private func openWith(_ app: URL) {
        let item = FileItem(name: doc.name, path: doc.path, isDir: false, size: 0, modified: nil, permissions: 0)
        model.sftp.editor = nil
        Task { await model.sftp.openWith(item, app: app) }
    }
}

/// NSTextView monospace dengan nomor baris & bilah cari (⌘F).
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.backgroundColor = NSColor(Theme.bg)
        tv.insertionPointColor = NSColor(Theme.accent)
        tv.string = text
        tv.delegate = context.coordinator
        scroll.drawsBackground = false
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.verticalRulerView = LineNumberRuler(textView: tv)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeTextView
        init(_ p: CodeTextView) { parent = p }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            tv.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// Kolom nomor baris di kiri editor.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        ruleThickness = 46
        clientView = textView
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        NSColor(Theme.panel).setFill()
        bounds.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let ns = tv.string as NSString
        var line = ns.substring(to: chars.location).reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
        var idx = chars.location
        let yOffset = tv.textContainerInset.height - visible.minY
        while idx < NSMaxRange(chars) || (idx == ns.length && idx == chars.location) {
            let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
            let g = lm.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: 0), actualCharacterRange: nil)
            let r = lm.lineFragmentRect(forGlyphAt: min(g.location, max(0, lm.numberOfGlyphs - 1)), effectiveRange: nil)
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: r.minY + yOffset + (r.height - size.height) / 2), withAttributes: attrs)
            line += 1
            if NSMaxRange(lineRange) <= idx { break }
            idx = NSMaxRange(lineRange)
            if idx >= ns.length { break }
        }
    }
}

// MARK: - Bilah file yang dibuka di aplikasi lain

struct WatchedFilesBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sftp = model.sftp
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                PhosphorIcon(sf: "arrow.triangle.2.circlepath", size: 13).foregroundStyle(Theme.accent)
                Text(L("Dibuka di aplikasi lain — disimpan otomatis ke server")).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 8)
            VStack(spacing: 4) {
                ForEach(sftp.watched) { w in
                    HStack(spacing: 8) {
                        PhosphorIcon(sf: fileIcon(w.localURL.lastPathComponent), size: 14).foregroundStyle(.secondary).frame(width: 16)
                        Text(w.localURL.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(L("di {}", w.appName)).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Spacer()
                        if w.uploading {
                            ProgressView().controlSize(.mini)
                        } else if let t = w.lastUpload {
                            PhosphorLabel(sf: "checkmark.circle.fill", text: L("Tersimpan {}", t.formatted(date: .omitted, time: .shortened)), size: 12)
                                .font(.system(size: 11)).foregroundStyle(Color(hex: "#4ADE80"))
                        }
                        Button(L("Berhenti")) { sftp.stopWatching(w) }.buttonStyle(.borderless).font(.caption)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(10)
        }
        .background(Theme.panel)
    }
}
