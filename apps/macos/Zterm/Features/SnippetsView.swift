import SwiftUI

struct SnippetsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Snippet?
    @State private var runTarget: Snippet?
    @State private var query = ""

    private var filtered: [Snippet] {
        let q = query.lowercased()
        return q.isEmpty ? model.snippets
            : model.snippets.filter { $0.label.lowercased().contains(q) || $0.command.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Snippets", subtitle: L("Perintah favorit — jalankan ke satu atau banyak host sekaligus")) {
                    SearchField(text: $query, prompt: L("Cari snippet…"))
                    Button { editing = .blank() } label: {
                        PhosphorLabel(text: L("Snippet Baru"), icon: "plus", size: 12,
                                      tint: Color(hex: "#06231E"))
                    }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if model.snippets.isEmpty {
                    EmptyState(ph: "brackets-curly", title: L("Belum ada snippet"),
                               text: L("Simpan perintah yang sering dipakai, misalnya cek disk atau restart service."))
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { i, s in
                            SnippetCard(snippet: s, onEdit: { editing = s }, onRun: { runTarget = s })
                                .staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $editing) { SnippetEditor(original: $0) }
        .sheet(item: $runTarget) { RunSnippetSheet(snippet: $0) }
    }
}

struct SnippetCard: View {
    @Environment(AppModel.self) private var model
    let snippet: Snippet
    var onEdit: () -> Void
    var onRun: () -> Void

    var body: some View {
        HoverCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent3.opacity(0.13))
                        RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent3.opacity(0.24))
                        PhosphorIcon(name: "brackets-curly", size: 15, tint: Theme.accent3)
                    }
                    .frame(width: 34, height: 34)
                    Text(snippet.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    IconButton(symbol: "pencil", help: L("Edit"), action: onEdit)
                    IconButton(symbol: "trash", help: L("Hapus"), tint: .red) { model.delete(snippet) }
                }
                Text(snippet.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    if model.activeSessionID != nil {
                        Button { model.runInActiveSession(snippet); model.flash(L("Dikirim ke tab aktif")) } label: {
                            PhosphorLabel(text: L("Tab aktif"), icon: "terminal-window", size: 12)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button(action: onRun) {
                        PhosphorLabel(text: L("Jalankan"), icon: "play", size: 12,
                                      tint: Color(hex: "#06231E"))
                    }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

struct SnippetEditor: View {
    @Environment(AppModel.self) private var model
    let original: Snippet
    @State private var label = ""
    @State private var command = ""

    var body: some View {
        FormSheet(title: original.id.isEmpty ? L("Snippet Baru") : L("Edit Snippet"),
                  canSave: !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  onSave: {
                      var s = original
                      s.label = label.isEmpty ? String(command.prefix(30)) : label
                      s.command = command
                      model.save(s)
                  }) {
            TextField(L("Nama (mis. Cek disk)"), text: $label).ztermField()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $command)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if command.isEmpty {
                    Text(L("df -h && free -m")).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary).padding(11).allowsHitTesting(false)
                }
            }
            .frame(height: 140)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
        }
        .onAppear { label = original.label; command = original.command }
    }
}

/// Pilih host lalu jalankan snippet: satu tab baru per host.
struct RunSnippetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let snippet: Snippet
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Jalankan “{}”", snippet.label)).font(.title3.bold())
            Text(snippet.command).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.hosts) { h in
                        let on = picked.contains(h.id)
                        HStack(spacing: 10) {
                            PhosphorIcon(name: on ? "check-circle" : "circle", size: 15,
                                         tint: on ? Theme.accent : .secondary)
                            Circle().fill(Color(hex: h.color)).frame(width: 8, height: 8)
                            Text(h.title)
                            Spacer()
                            if let g = h.group { Text(g).font(.caption).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(on ? Theme.accent.opacity(0.1) : Theme.card, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(.ztermSnappy) { if on { picked.remove(h.id) } else { picked.insert(h.id) } } }
                    }
                }
            }
            .frame(height: 240)
            HStack {
                Button(picked.count == model.hosts.count ? L("Batal pilih semua") : L("Pilih semua")) {
                    withAnimation(.ztermSnappy) { picked = picked.count == model.hosts.count ? [] : Set(model.hosts.map(\.id)) }
                }
                .buttonStyle(.borderless)
                Spacer()
                Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button {
                    model.connect(model.hosts.map(\.id).filter(picked.contains), run: snippet.command)
                    dismiss()
                } label: {
                    PhosphorLabel(text: L("Jalankan di {} host", picked.count), icon: "play", size: 12,
                                  tint: Color(hex: "#06231E"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(picked.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// Kolom cari kecil yang seragam di header halaman.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        HStack(spacing: 7) {
            PhosphorIcon(name: "magnifying-glass", size: 13, tint: .secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).frame(width: 170)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardStroke))
    }
}

extension Snippet {
    static func blank() -> Snippet { Snippet(id: "", label: "", command: "", updatedAt: 0, deleted: false) }
}
