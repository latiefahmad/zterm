import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drag & drop
//
// • Baris di panel Mac      → menyediakan file URL (bisa ke Finder / panel server).
// • Baris di panel server   → menyediakan file (di-download saat dilepas di Finder) dan token
//                             "zterm-remote:<path>" untuk drop di dalam app tanpa download ganda.
// • Banyak file sekaligus   → jika baris yang di-drag termasuk pilihan, semua yang dipilih ikut.

private let remoteToken = "zterm-remote:"

/// Akses model dari Transferable (yang tidak punya environment).
@MainActor
enum SftpDragContext {
    static weak var model: SftpModel?
}

struct RemoteDragItem: Transferable {
    let item: FileItem

    static var transferRepresentation: some TransferRepresentation {
        // Untuk Finder: download dulu ke folder sementara, lalu Finder menyalinnya ke tujuan drop.
        FileRepresentation(exportedContentType: .item) { d in
            guard let model = await SftpDragContext.model else { throw CoreError.NotFound }
            let url = try await model.exportForDrag(d.item)
            return SentTransferredFile(url, allowAccessingOriginalFile: true)
        }
        // Untuk drop di dalam app (panel Mac / folder server).
        ProxyRepresentation(exporting: { (d: RemoteDragItem) in remoteToken + d.item.path })
    }
}

/// Provider untuk drop dari dalam app: cek token server dulu agar tidak memicu download ke folder sementara.
@MainActor
func readInAppOrFiles(_ providers: [NSItemProvider], completion: @escaping ([String], [URL]) -> Void) {
    var remote: [String] = [], files: [URL] = []
    let group = DispatchGroup()
    let lock = NSLock()
    for p in providers {
        group.enter()
        let textType = [UTType.utf8PlainText, .plainText].first { p.hasItemConformingToTypeIdentifier($0.identifier) }
        if let textType {
            p.loadDataRepresentation(forTypeIdentifier: textType.identifier) { data, _ in
                if let data, let s = String(data: data, encoding: .utf8), s.hasPrefix(remoteToken) {
                    lock.lock(); remote.append(String(s.dropFirst(remoteToken.count))); lock.unlock()
                    group.leave()
                } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = p.loadObject(ofClass: NSURL.self) { u, _ in
                        if let u = u as? URL { lock.lock(); files.append(u); lock.unlock() }
                        group.leave()
                    }
                } else {
                    group.leave()
                }
            }
        } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = p.loadObject(ofClass: NSURL.self) { u, _ in
                if let u = u as? URL { lock.lock(); files.append(u); lock.unlock() }
                group.leave()
            }
        } else {
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(remote, files) }
}

private let dropTypes: [UTType] = [.utf8PlainText, .plainText, .fileURL]

// MARK: - Panel Mac

struct LocalPane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var dropTarget = false

    var body: some View {
        let sftp = model.sftp
        FilePane(
            title: L("Mac ini"), icon: "laptopcomputer", path: sftp.localPath, items: sftp.localItems,
            selection: $selection, isDropTarget: dropTarget, dropHint: L("Lepas untuk download / salin ke sini"),
            onOpen: { item in if item.isDir { sftp.openLocal(item.path) } else { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) } },
            onUp: { sftp.localUp() },
            onRefresh: { sftp.reloadLocal() },
            onPath: { sftp.openLocal($0) },
            transferTitle: L("Upload"), transferIcon: "arrow.up.circle.fill",
            onTransfer: { sftp.upload(selected.map(\.path)); selection.removeAll() },
            dragItem: { item in
                // Seret banyak file sekaligus jika baris ini bagian dari pilihan
                let paths = selection.contains(item.id) ? selected.map(\.path) : [item.path]
                let p = NSItemProvider(object: URL(fileURLWithPath: item.path) as NSURL)
                sftp.dragging = (false, paths)
                return p
            },
            onDropOnFolder: { folder, providers in handleDrop(providers, into: folder.path) }
        ) { item in
            Button(L("Upload ke server")) { sftp.upload([item.path]) }
            Button(L("Tampilkan di Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
        } toolbarExtra: {
            IconButton(symbol: "house", help: L("Home")) { sftp.openLocal(FileManager.default.homeDirectoryForCurrentUser.path) }
        }
        .onDrop(of: dropTypes, isTargeted: $dropTarget) { providers in
            handleDrop(providers, into: sftp.localPath)
            return true
        }
        .onChange(of: sftp.localPath) { _, _ in selection.removeAll() }
    }

    private var selected: [FileItem] { model.sftp.localItems.filter { selection.contains($0.id) } }

    private func handleDrop(_ providers: [NSItemProvider], into dir: String) {
        let sftp = model.sftp
        readInAppOrFiles(providers) { remote, files in
            if !remote.isEmpty {
                // Dari panel server → download (semua yang dipilih jika item termasuk pilihan)
                let items = sftp.remoteItems.filter { remote.contains($0.path) || (sftp.remoteSelection.contains($0.path) && remote.contains(where: sftp.remoteSelection.contains)) }
                sftp.download(items.isEmpty ? remote.map { FileItem(name: ($0 as NSString).lastPathComponent, path: $0, isDir: false, size: 0, modified: nil, permissions: 0) } : items, into: dir)
            } else if !files.isEmpty {
                // Dari Finder → salin ke folder Mac ini
                let saved = sftp.localPath
                sftp.localPath = dir
                sftp.copyIntoLocal(files)
                if dir != saved { sftp.localPath = saved; sftp.reloadLocal() }
            }
        }
    }
}

// MARK: - Panel server

struct RemotePane: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var dropTarget = false
    @State private var renaming: FileItem?
    @State private var chmodding: FileItem?
    @State private var newFolder = false
    @State private var confirmDelete: [FileItem] = []

    var body: some View {
        let sftp = model.sftp
        FilePane(
            title: sftp.host?.title ?? L("Server"), icon: "server.rack", path: sftp.remotePath, items: sftp.remoteItems,
            selection: $selection, isDropTarget: dropTarget, loading: sftp.remoteLoading, dropHint: L("Lepas untuk upload ke sini"),
            onOpen: { item in
                if item.isDir { Task { await sftp.openRemote(item.path) } }
                else if RemoteFiles.isTextLike(item) { Task { await sftp.openEditor(item) } }
                else { Task { await sftp.openWith(item) } }
            },
            onUp: { Task { await sftp.remoteUp() } },
            onRefresh: { Task { await sftp.refreshRemote() } },
            onPath: { p in Task { await sftp.openRemote(p) } },
            transferTitle: L("Download"), transferIcon: "arrow.down.circle.fill",
            onTransfer: { sftp.download(selected); selection.removeAll() },
            remoteDrag: { RemoteDragItem(item: $0) },
            onDropOnFolder: { folder, providers in handleDrop(providers, into: folder.path) }
        ) { item in
            if !item.isDir {
                Button(L("Edit di Zterm")) { Task { await sftp.openEditor(item) } }
                    .disabled(item.size > RemoteFiles.editorLimit)
                Menu(L("Buka dengan")) {
                    let apps = RemoteFiles.apps(for: item.name)
                    if let def = apps.first {
                        Button(L("{} (bawaan)", RemoteFiles.appName(def))) { Task { await sftp.openWith(item, app: def) } }
                        Divider()
                    }
                    ForEach(apps.dropFirst(), id: \.self) { app in
                        Button(RemoteFiles.appName(app)) { Task { await sftp.openWith(item, app: app) } }
                    }
                    Divider()
                    Button(L("Aplikasi lain…")) { sftp.chooseAppAndOpen(item) }
                }
                Divider()
            }
            Button(L("Download ke Mac")) { sftp.download([item]) }
            Button(L("Ganti nama…")) { renaming = item }
            Button(L("Ubah izin (chmod)…")) { chmodding = item }
            Button(L("Salin path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button(L("Hapus"), role: .destructive) { confirmDelete = selection.contains(item.id) ? selected : [item] }
        } toolbarExtra: {
            IconButton(symbol: "house", help: L("Home")) { Task { await sftp.remoteHome() } }
            IconButton(symbol: "folder.badge.plus", help: L("Folder baru")) { newFolder = true }
            IconButton(symbol: "trash", help: L("Hapus yang dipilih"), tint: .red) { confirmDelete = selected }
                .disabled(selection.isEmpty)
        }
        .onDrop(of: dropTypes, isTargeted: $dropTarget) { providers in
            handleDrop(providers, into: sftp.remotePath)
            return true
        }
        .onChange(of: selection) { _, s in sftp.remoteSelection = s }
        .onChange(of: sftp.remotePath) { _, _ in selection.removeAll() }
        .sheet(item: $renaming) { item in
            TextPromptSheet(title: L("Ganti nama"), initial: item.name, action: L("Simpan")) { name in
                Task { await sftp.renameRemote(item, to: name) }
            }
        }
        .sheet(item: $chmodding) { item in ChmodSheet(item: item) { mode in Task { await sftp.chmodRemote(item, mode: mode) } } }
        .sheet(isPresented: $newFolder) {
            TextPromptSheet(title: L("Folder baru"), initial: L("folder-baru"), action: L("Buat")) { name in
                Task { await sftp.mkdirRemote(name) }
            }
        }
        .confirmationDialog(L("Hapus {} item dari server?", confirmDelete.count),
                            isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button(L("Hapus"), role: .destructive) {
                let items = confirmDelete
                selection.removeAll()
                Task { await sftp.deleteRemote(items) }
            }
        } message: {
            Text(confirmDelete.map(\.name).prefix(5).joined(separator: ", ") + L(" — tidak bisa dibatalkan. Folder dihapus beserta isinya."))
        }
    }

    private var selected: [FileItem] { model.sftp.remoteItems.filter { selection.contains($0.id) } }

    private func handleDrop(_ providers: [NSItemProvider], into dir: String) {
        let sftp = model.sftp
        readInAppOrFiles(providers) { remote, files in
            if !remote.isEmpty {
                // Item server dilepas di folder server lain → pindahkan
                Task { await sftp.moveRemote(remote.filter { ($0 as NSString).deletingLastPathComponent != dir && $0 != dir }, into: dir) }
            } else if !files.isEmpty {
                // Dari panel Mac (bisa banyak yang dipilih) atau dari Finder → upload
                var paths = files.map(\.path)
                if let d = sftp.dragging, !d.remote, paths.count == 1, d.paths.contains(paths[0]) { paths = d.paths }
                sftp.dragging = nil
                sftp.upload(paths, into: dir)
            }
        }
    }
}

// MARK: - Panel file (dipakai kedua sisi)

struct FilePane<RowMenu: View, Extra: View>: View {
    let title: String
    let icon: String
    let path: String
    let items: [FileItem]
    @Binding var selection: Set<String>
    var isDropTarget = false
    var loading = false
    var dropHint: String
    var onOpen: (FileItem) -> Void
    var onUp: () -> Void
    var onRefresh: () -> Void
    var onPath: (String) -> Void
    var transferTitle: String
    var transferIcon: String
    var onTransfer: () -> Void
    var dragItem: ((FileItem) -> NSItemProvider)? = nil
    var remoteDrag: ((FileItem) -> RemoteDragItem)? = nil
    var onDropOnFolder: (FileItem, [NSItemProvider]) -> Void
    @ViewBuilder var rowMenu: (FileItem) -> RowMenu
    @ViewBuilder var toolbarExtra: () -> Extra

    @State private var editingPath = false
    @State private var pathText = ""
    @State private var anchor: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                PhosphorIcon(sf: icon, size: 14).foregroundStyle(Theme.accent)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                IconButton(symbol: "chevron.up", help: L("Folder induk"), action: onUp)
                IconButton(symbol: "arrow.clockwise", help: L("Muat ulang"), action: onRefresh)
                toolbarExtra()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Group {
                if editingPath {
                    TextField(L("Path"), text: $pathText, onCommit: { onPath(pathText); editingPath = false })
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    Breadcrumb(path: path, onTap: onPath)
                        .onTapGesture(count: 2) { pathText = path; editingPath = true }
                }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 12).padding(.bottom, 8)

            HStack(spacing: 0) {
                Text(L("Nama")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Ukuran")).frame(width: 76, alignment: .trailing)
                Text(L("Diubah")).frame(width: 118, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 22).padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        row(item, index: i)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 8)
                .animation(.ztermSnappy, value: items.map(\.id))
            }
            .overlay {
                if items.isEmpty && !loading {
                    VStack(spacing: 6) {
                        PhosphorIcon(sf: "tray", size: 26).foregroundStyle(.tertiary)
                        Text(L("Folder kosong")).foregroundStyle(.secondary)
                        Text(L("Seret file ke sini")).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.removeAll() }

            HStack {
                Text(selection.isEmpty ? L("{} item", items.count) : L("{} dipilih", selection.count))
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button(action: onTransfer) { PhosphorLabel(sf: transferIcon, text: transferTitle, size: 12) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selection.isEmpty)
            }
            .padding(10)
        }
        .background(Theme.bg)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        VStack(spacing: 8) {
                            PhosphorIcon(sf: transferIcon == "arrow.up.circle.fill" ? "arrow.down.doc.fill" : "arrow.up.doc.fill", size: 30)
                            Text(dropHint).font(.headline)
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(18)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.ztermSnappy, value: isDropTarget)
    }

    @ViewBuilder
    private func row(_ item: FileItem, index: Int) -> some View {
        let r = FileRow(item: item, selected: selection.contains(item.id), canDropInto: item.isDir) { providers in
            onDropOnFolder(item, providers)
        }
        .contentShape(Rectangle())
        // Satu gesture: langsung merespons; klik ganda dibaca dari jumlah klik macOS
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onOpen(item) } else { select(item) }
        }
        .contextMenu {
            rowMenu(item)
        }
        if let remoteDrag {
            r.draggable(remoteDrag(item)) { DragPreview(item: item, count: selection.contains(item.id) ? selection.count : 1) }
        } else if let dragItem {
            r.onDrag { dragItem(item) } preview: { DragPreview(item: item, count: selection.contains(item.id) ? selection.count : 1) }
        } else {
            r
        }
    }

    /// Klik = pilih satu, ⌘-klik = tambah/kurang, ⇧-klik = rentang.
    private func select(_ item: FileItem) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if mods.contains(.shift), let a = anchor,
                  let i = items.firstIndex(where: { $0.id == a }), let j = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(i, j)...max(i, j)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }
}

struct FileRow: View {
    let item: FileItem
    let selected: Bool
    let canDropInto: Bool
    var onDrop: ([NSItemProvider]) -> Void
    @State private var hover = false
    @State private var dropHover = false

    var body: some View {
        HStack(spacing: 9) {
            PhosphorIcon(sf: item.isDir ? (dropHover ? "folder.fill.badge.plus" : "folder.fill") : fileIcon(item.name), size: 14)
                .foregroundStyle(item.isDir ? Theme.accent2 : .secondary)
                .frame(width: 18)
            Text(item.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(item.isDir ? "—" : item.size.byteString)
                .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(dropHover ? Theme.accent.opacity(0.22)
                      : selected ? Theme.accent.opacity(0.16)
                      : hover ? Theme.ink.opacity(0.05) : .clear)
        }
        .overlay {
            if dropHover {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5)
            }
        }
        .scaleEffect(dropHover ? 1.015 : 1)
        .animation(.ztermHover, value: hover)
        .animation(.ztermSnappy, value: dropHover)
        .onHover { hover = $0 }
        .modifier(FolderDrop(enabled: canDropInto, hovering: $dropHover, onDrop: onDrop))
    }
}

/// Folder bisa menerima drop langsung (file masuk ke folder tersebut).
private struct FolderDrop: ViewModifier {
    let enabled: Bool
    @Binding var hovering: Bool
    var onDrop: ([NSItemProvider]) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: dropTypes, isTargeted: $hovering) { providers in
                onDrop(providers)
                return true
            }
        } else {
            content
        }
    }
}

/// Pratinjau saat di-drag: ikon + nama (+ jumlah jika banyak).
struct DragPreview: View {
    let item: FileItem
    let count: Int
    var body: some View {
        HStack(spacing: 8) {
            PhosphorIcon(sf: item.isDir ? "folder.fill" : fileIcon(item.name), size: 13).foregroundStyle(Theme.accent)
            Text(count > 1 ? L("{} item", count) : item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
    }
}

func fileIcon(_ name: String) -> String {
    switch (name as NSString).pathExtension.lowercased() {
    case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": "photo"
    case "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar": "doc.zipper"
    case "sh", "py", "js", "ts", "rb", "go", "rs", "php", "swift", "java", "c", "h", "cpp": "chevron.left.forwardslash.chevron.right"
    case "json", "yml", "yaml", "toml", "xml", "conf", "ini", "env": "gearshape"
    case "log", "txt", "md": "doc.text"
    case "sql", "db", "sqlite": "cylinder"
    case "pdf": "doc.richtext"
    case "mp4", "mov", "mkv": "film"
    case "mp3", "wav", "m4a": "music.note"
    default: "doc"
    }
}
