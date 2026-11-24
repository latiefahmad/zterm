import SwiftUI

/// Semua tab terminal dalam satu ZStack. Tab biasa memenuhi area; saat split aktif, panel split
/// ditata berdampingan (2 kolom, 3 kolom, atau 2×2). View terminal tidak pernah dibuat ulang —
/// hanya posisi & ukurannya yang berubah, jadi sesi tetap hidup.
struct TerminalPanes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let split = model.splitVisible ? model.splitIDs : []
            ZStack(alignment: .topLeading) {
                ForEach(model.sessions) { s in
                    let index = split.firstIndex(of: s.id)
                    let rect = index.map { cell($0, count: split.count, in: geo.size) } ?? CGRect(origin: .zero, size: geo.size)
                    let visible = index != nil || s.id == model.activeSessionID
                    let focused = s.id == model.activeSessionID
                    VStack(spacing: 0) {
                        if index != nil { PaneHeader(session: s, focused: focused) }
                        TerminalPane(session: s, active: visible, focused: focused)
                    }
                    .overlay {
                        if index != nil {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(borderColor(focused: focused), lineWidth: focused || model.broadcast ? 1.5 : 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .zIndex(visible ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                if model.splitVisible && model.broadcast {
                    Label(L("Broadcast aktif — ketikan dikirim ke {} terminal", model.splitIDs.count), systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.8))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.orange, in: Capsule())
                        .shadow(color: .orange.opacity(0.4), radius: 12)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
        .animation(.ztermSnappy, value: model.splitIDs)
        .animation(.ztermSnappy, value: model.broadcast)
        .onAppear { PaneFocus.install(model: model) }
    }

    private func borderColor(focused: Bool) -> Color {
        if model.broadcast { return .orange.opacity(focused ? 0.95 : 0.55) }
        return focused ? Theme.accent.opacity(0.85) : Theme.ink.opacity(0.12)
    }

    /// Kotak panel ke-`i` dari `count` panel.
    private func cell(_ i: Int, count: Int, in size: CGSize) -> CGRect {
        let gap: CGFloat = 4
        let cols = count == 4 ? 2 : count
        let rows = count == 4 ? 2 : 1
        let w = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let h = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        let c = i % cols, r = i / cols
        return CGRect(x: CGFloat(c) * (w + gap), y: CGFloat(r) * (h + gap), width: w, height: h)
    }
}

/// Klik di dalam panel split menjadikannya panel aktif (view terminal menangkap klik sendiri,
/// jadi dideteksi lewat monitor event, bukan gesture SwiftUI).
@MainActor
enum PaneFocus {
    private static var monitor: Any?

    static func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak model] event in
            guard let model, model.splitVisible, let content = event.window?.contentView,
                  let hit = content.hitTest(event.locationInWindow) else { return event }
            for s in model.sessions where model.splitIDs.contains(s.id) {
                if hit === s.view || hit.isDescendant(of: s.view) {
                    model.focusPane(s.id)
                    break
                }
            }
            return event
        }
    }
}

/// Judul kecil di atas tiap panel split.
private struct PaneHeader: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: session.host.color)).frame(width: 7, height: 7)
            Text(session.title).font(.system(size: 11.5, weight: focused ? .semibold : .regular)).lineLimit(1)
            if model.broadcast {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundStyle(.orange)
            }
            Spacer()
            Button { model.removeFromSplit(session.id) } label: {
                Image(systemName: "rectangle.badge.minus").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(L("Keluarkan dari split (tab tetap terbuka)"))
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(focused ? Theme.accent.opacity(0.1) : Theme.ink.opacity(0.04))
        .foregroundStyle(focused ? .primary : .secondary)
        .contentShape(Rectangle())
        .onTapGesture {
            model.activeSessionID = session.id
            session.view.window?.makeFirstResponder(session.view)
        }
    }
}

/// Menu Split di bar tab: duplikat, gabung tab lain, atau host baru.
struct SplitMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let others = model.sessions.filter { s in s.id != model.activeSessionID && !(model.splitVisible && model.splitIDs.contains(s.id)) }
        Menu {
            Button { model.splitDuplicate() } label: { Label(L("Duplikat tab ini"), systemImage: "plus.square.on.square") }
                .keyboardShortcut("d")
                .disabled(!model.canSplit)
            if !others.isEmpty {
                Menu(L("Gabung tab")) {
                    ForEach(others) { s in Button(s.title) { model.split(with: s) } }
                }
                .disabled(!model.canSplit)
            }
            if !model.hosts.isEmpty {
                Menu(L("Host baru")) {
                    ForEach(model.hosts) { h in Button(h.title) { model.splitNew(h) } }
                }
                .disabled(!model.canSplit)
            }
            if model.splitVisible {
                Divider()
                Button(model.broadcast ? L("Matikan broadcast") : L("Broadcast ke semua panel")) { model.toggleBroadcast() }
                Button(L("Keluar dari split")) { model.unsplit() }
            }
        } label: {
            Label(model.splitVisible ? L("Split · {}", model.splitIDs.count) : L("Split"), systemImage: "rectangle.split.2x1")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Bagi layar: 2–4 terminal berdampingan (⌘D)"))
    }
}
