import SwiftUI

/// Judul halaman yang seragam: judul besar, subjudul, dan tombol aksi di kanan.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.2)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            actions()
        }
    }
}

/// Keadaan kosong dengan ikon datar di dalam kotak netral.
struct EmptyState: View {
    private let sfSymbol: String?
    private let phosphor: String?
    let title: String
    let text: String

    init(icon: String, title: String, text: String) {
        sfSymbol = icon
        phosphor = nil
        self.title = title
        self.text = text
    }

    init(ph: String, title: String, text: String) {
        sfSymbol = nil
        phosphor = ph
        self.title = title
        self.text = text
    }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.ink.opacity(0.05))
                    .frame(width: 64, height: 64)
                if let phosphor {
                    PhosphorIcon(name: phosphor, size: 30, tint: Theme.accent)
                } else if let sfSymbol {
                    PhosphorIcon(sf: sfSymbol, size: 28, tint: Theme.accent)
                }
            }
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}

/// Baris/kartu dengan sorotan garis yang seragam.
struct HoverCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? Theme.ink.opacity(0.16) : Theme.cardStroke))
            .animation(.ztermHover, value: hover)
            .onHover { hover = $0 }
    }
}

/// Lencana kecil berwarna.
struct Badge: View {
    let text: String
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(color)
    }
}

/// Sheet form standar: judul, isi, tombol Batal / Simpan.
struct FormSheet<Content: View>: View {
    let title: String
    var saveTitle = L("Simpan")
    var canSave = true
    var onSave: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            content()
            HStack {
                Spacer()
                Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(saveTitle) { onSave(); dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
    }
}
