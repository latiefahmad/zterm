import SwiftUI

/// Judul halaman yang seragam: judul besar, subjudul, dan tombol aksi di kanan.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            actions()
        }
    }
}

/// Keadaan kosong dengan ikon melayang.
struct EmptyState: View {
    let icon: String
    let title: String
    let text: String
    @State private var float = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.brandGradient)
                .offset(y: float ? -4 : 4)
                .animation(.easeInOut(duration: 2).repeatForever(), value: float)
            Text(title).font(.title3.bold())
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .onAppear { float = true }
    }
}

/// Baris/kartu dengan efek hover yang seragam.
struct HoverCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    @State private var hover = false

    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.cardHover : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.ink.opacity(hover ? 0.14 : 0.08)))
            .shadow(color: Theme.shadow.opacity(hover ? 1 : 0), radius: 12, y: 6)
            .offset(y: hover ? -1 : 0)
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
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
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
