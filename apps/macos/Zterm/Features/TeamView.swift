import SwiftUI

enum TeamLinks {
    static let joinPage = URL(string: "https://latiefahmad.github.io/zterm/team.html")!
}

/// Halaman Tim: admin membagikan host ke email rekan; anggota melihat host tim di daftar Hosts.
struct TeamView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false
    @State private var joining = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: L("Tim"), subtitle: L("Bagikan host ke rekan kerja — terenkripsi end-to-end lewat Google Drive")) {
                    if model.teamReady {
                        if model.teamBusy { ProgressView().controlSize(.small) }
                        Button { joining = true } label: { Label(L("Gabung tim"), systemImage: "person.badge.plus") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button { creating = true } label: { Label(L("Buat tim"), systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }

                if let err = model.teamError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity)
                }

                if !model.teamReady {
                    TeamSetupCard()
                } else {
                    if !model.teamInvites.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: L("Undangan"))
                            ForEach(model.teamInvites, id: \.fileId) { inv in InviteRow(invite: inv) }
                        }
                    }
                    if model.teams.isEmpty {
                        TeamIntro()
                    } else {
                        ForEach(Array(model.teams.enumerated()), id: \.element.id) { i, t in
                            TeamCard(team: t).staggerIn(i, base: 0)
                        }
                    }
                }
            }
            .padding(28)
            .animation(.zterm, value: model.teams)
            .animation(.zterm, value: model.teamError)
        }
        .sheet(isPresented: $creating) { CreateTeamSheet() }
        .sheet(isPresented: $joining) { JoinTeamSheet() }
        .task {
            await model.syncTeams()
            await model.refreshInvites()
        }
    }
}

private struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold)).tracking(1.2)
            .foregroundStyle(.secondary)
    }
}

/// Belum login Google / login lama tanpa izin drive.file.
private struct TeamSetupCard: View {
    @Environment(AppModel.self) private var model
    @State private var working = false

    var body: some View {
        HoverCard(padding: 22) {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: "person.2.badge.key.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.brandGradient)
                    .frame(width: 56, height: 56)
                    .background(Theme.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.accountEmail == nil ? L("Masuk dengan Google untuk memakai Tim") : L("Izinkan Zterm mengelola file Tim"))
                        .font(.title3.bold())
                    Text(model.accountEmail == nil
                         ? L("Tim memakai Google Drive milik admin untuk menyimpan host yang dibagikan. Isinya terenkripsi — Google tidak bisa membacanya.")
                         : L("Tim butuh izin Google Drive tambahan: hanya file yang dibuat atau kamu pilih di Zterm — bukan seluruh Drive-mu. Masuk ulang dengan Google lalu centang izin Drive."))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        working = true
                        Task { await model.grantTeamAccess(); working = false }
                    } label: {
                        Label(model.accountEmail == nil ? L("Masuk dengan Google") : L("Izinkan akses Google Drive"), systemImage: "g.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working)
                    .padding(.top, 4)
                }
            }
        }
    }
}

/// Penjelasan singkat saat belum ada tim.
private struct TeamIntro: View {
    var body: some View {
        VStack(spacing: 18) {
            EmptyState(icon: "person.2.fill", title: L("Belum ada tim"),
                       text: L("Buat tim untuk membagikan host ke rekan kerja, atau gabung ke tim yang mengundangmu."))
            HStack(alignment: .top, spacing: 12) {
                step(1, L("Buat tim"), L("Pilih host yang dibagikan — password & SSH key ikut, terenkripsi."))
                step(2, L("Undang email"), L("Google mengirim email undangan ke rekanmu."))
                step(3, L("Rekan bergabung"), L("Mereka klik Gabung tim di Zterm; host muncul di daftar Hosts."))
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22)
                .background(Theme.brandGradient, in: Circle()).foregroundStyle(.black.opacity(0.75))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardStroke))
    }
}

private struct InviteRow: View {
    @Environment(AppModel.self) private var model
    let invite: TeamInvite
    @State private var working = false

    var body: some View {
        HoverCard(padding: 12) {
            HStack(spacing: 12) {
                Image(systemName: "envelope.open.fill").foregroundStyle(Section.team.tint)
                    .frame(width: 34, height: 34)
                    .background(Section.team.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(invite.name).font(.system(size: 13, weight: .semibold))
                    Text(L("dari {}", invite.ownerEmail)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(working ? L("Bergabung…") : L("Gabung")) {
                    working = true
                    Task { _ = await model.joinTeam(fileId: invite.fileId); working = false }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working)
            }
        }
    }
}

// MARK: - Kartu tim

private struct TeamCard: View {
    @Environment(AppModel.self) private var model
    let team: TeamInfo
    @State private var inviteEmail = ""
    @State private var sharing = false
    @State private var confirmLeave = false
    @State private var removing: String?

    private var sharedHosts: [Host] {
        model.ownHosts.filter { team.sharedHostIds.contains($0.id) }
    }
    private var memberHosts: [Host] {
        model.hosts.filter { $0.id.hasPrefix("team:\(team.id):") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if team.isOwner { ownerBody } else { memberBody }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.cardStroke))
        .sheet(isPresented: $sharing) { ShareHostsSheet(team: team) }
        .confirmationDialog(team.isOwner ? L("Hapus tim {}?", team.name) : L("Keluar dari {}?", team.name), isPresented: $confirmLeave) {
            Button(team.isOwner ? L("Hapus tim") : (L10n.shared.english ? "Leave" : "Keluar"), role: .destructive) { Task { await model.leaveTeam(team) } }
        } message: {
            Text(team.isOwner
                 ? L("File tim dipindah ke sampah Google Drive-mu dan semua anggota kehilangan akses ke host tim.")
                 : L("Host tim hilang dari Zterm-mu. Admin bisa mengundangmu lagi nanti."))
        }
        .confirmationDialog(L("Keluarkan {}?", removing ?? ""), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("Keluarkan"), role: .destructive) {
                if let e = removing { Task { await model.removeFromTeam(team, email: e) } }
            }
        } message: {
            Text(L("Akses Google Drive-nya dicabut dan kunci tim diganti, jadi perubahan host berikutnya tidak bisa dibaca lagi olehnya. Ganti juga password server yang sempat ia lihat."))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.black.opacity(0.72))
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [Section.team.tint, Section.team.tint.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(team.name).font(.system(size: 17, weight: .bold))
                    Badge(text: team.isOwner ? "ADMIN" : L("ANGGOTA"), color: team.isOwner ? Theme.accent : Theme.accent2)
                    if !team.isOwner { statusBadge }
                }
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button(L("Sinkronkan sekarang")) { Task { await model.syncTeams() } }
                Divider()
                Button(team.isOwner ? L("Hapus tim…") : L("Keluar dari tim…"), role: .destructive) { confirmLeave = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private var subtitle: String {
        var parts = [team.isOwner ? L("{} anggota", team.members.count) : L("Admin: {}", team.ownerEmail)]
        if team.lastSync > 0 {
            let style = Date.RelativeFormatStyle(presentation: .named, locale: Locale(identifier: AppLanguage.resolved))
            parts.append(L("disinkron {}", Date(ms: team.lastSync).formatted(style)))
        }
        if let e = team.error { parts.append("⚠︎ " + e) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusBadge: some View {
        switch team.status {
        case .active: Badge(text: L("AKTIF"), color: Color(hex: "#4ADE80"))
        case .waiting: Badge(text: L("MENUNGGU ADMIN"), color: .orange)
        case .revoked: Badge(text: L("AKSES DICABUT"), color: .red)
        }
    }

    // MARK: Admin

    private var ownerBody: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: L("Anggota"))
                VStack(spacing: 0) {
                    ForEach(team.members, id: \.email) { m in
                        HStack(spacing: 10) {
                            MemberAvatar(email: m.email)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.email).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(m.isAdmin ? L("Admin") : m.status == .joined ? L("Aktif") : L("Belum bergabung di Zterm"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(m.isAdmin || m.status == .joined ? .secondary : Color.orange)
                            }
                            Spacer()
                            if !m.isAdmin {
                                IconButton(symbol: "person.fill.xmark", help: L("Keluarkan dari tim"), tint: .red) { removing = m.email }
                            }
                        }
                        .padding(.vertical, 7)
                        if m.email != team.members.last?.email { Divider().opacity(0.5) }
                    }
                }
                HStack(spacing: 8) {
                    TextField(L("email@rekan.com"), text: $inviteEmail)
                        .ztermField()
                        .onSubmit(invite)
                    Button(L("Undang"), action: invite)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!inviteEmail.contains("@") || model.teamBusy)
                }
                Text(L("Google mengirim email undangan. Rekan lalu membuka Tim → Gabung tim di Zterm miliknya, masuk dengan email yang diundang."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: L("Host dibagikan"))
                    Spacer()
                    Button { sharing = true } label: { Label(L("Pilih host"), systemImage: "checklist") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if sharedHosts.isEmpty {
                    Text(L("Belum ada host yang dibagikan."))
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 6) {
                        ForEach(sharedHosts) { h in HostChip(host: h) }
                    }
                }
                Text(L("Password & SSH key host ikut dibagikan, terenkripsi. Perubahan host otomatis terkirim ke anggota."))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func invite() {
        let email = inviteEmail.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { return }
        Task { if await model.inviteToTeam(team, email: email) { inviteEmail = "" } }
    }

    // MARK: Anggota

    @ViewBuilder private var memberBody: some View {
        switch team.status {
        case .active:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: L("{} host dari tim", memberHosts.count))
                    Spacer()
                    Button { withAnimation(.zterm) { model.section = .hosts } } label: { Label(L("Buka Hosts"), systemImage: "server.rack") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                    ForEach(memberHosts) { h in HostChip(host: h) }
                }
            }
        case .waiting where team.error != nil:
            Label(Lmsg(team.error ?? ""), systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .waiting:
            Label(L("Menunggu {} membuka Zterm agar kunci tim terkirim. Host tim muncul otomatis setelah itu.", team.ownerEmail),
                  systemImage: "hourglass")
                .font(.callout).foregroundStyle(.secondary)
        case .revoked:
            Label(L("Akses ke tim ini sudah dicabut atau timnya dihapus."), systemImage: "lock.slash")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct MemberAvatar: View {
    let email: String
    var body: some View {
        Text(String(email.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .bold))
            .frame(width: 28, height: 28)
            .background(Color(hex: Theme.hostColors[abs(email.hashValue) % Theme.hostColors.count]).opacity(0.25), in: Circle())
    }
}

private struct HostChip: View {
    @Environment(AppModel.self) private var model
    @AppStorage(PrivacyKeys.hideAddresses) private var hideAddresses = true
    let host: Host

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: host.color)).frame(width: 8, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(host.displayAddress(hidden: hideAddresses)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: host.auth == .key ? "key.fill" : host.auth == .agent ? "person.badge.key" : "ellipsis.rectangle")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
            if host.isTeam {
                IconButton(symbol: "play.fill", help: L("Connect")) { model.connect([host.id]) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Sheet

private struct CreateTeamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Buat tim")).font(.title3.bold())
            Text(L("File tim dibuat di Google Drive-mu ({}). Kamu jadi admin: yang bisa mengundang dan memilih host.", model.accountEmail ?? L("akun Google")))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L("Nama tim (mis. Tim Ops)"), text: $name).ztermField().onSubmit(create)
            HStack {
                Spacer()
                Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(working ? L("Membuat…") : L("Buat tim"), action: create)
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(24).frame(width: 460)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        working = true
        Task {
            if await model.createTeam(name: name.trimmingCharacters(in: .whitespaces)) { dismiss() }
            working = false
        }
    }
}

private struct JoinTeamSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var checking = false
    @State private var link = ""
    @State private var joining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Gabung tim")).font(.title3.bold())
            VStack(alignment: .leading, spacing: 12) {
                row(1, L("Buka halaman Gabung tim"), L("Masuk dengan akun Google yang diundang ({}), lalu pilih file tim.", model.accountEmail ?? "-")) {
                    Button { openURL(TeamLinks.joinPage) } label: { Label(L("Buka halaman"), systemImage: "safari") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                row(2, L("Kembali ke sini"), L("Undangan yang sudah kamu pilih muncul di bawah.")) {
                    Button {
                        checking = true
                        Task { await model.refreshInvites(); checking = false }
                    } label: { Label(checking ? L("Mengecek…") : L("Cek undangan"), systemImage: "arrow.clockwise") }
                        .buttonStyle(SecondaryButtonStyle()).disabled(checking)
                }
            }
            if !model.teamInvites.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.teamInvites, id: \.fileId) { inv in InviteRow(invite: inv) }
                }
            }
            Divider()
            Text(L("Atau tempel link / ID file tim dari halaman Gabung tim:")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(L("https://drive.google.com/file/d/…"), text: $link).ztermField()
                Button(joining ? L("Bergabung…") : L("Gabung")) {
                    joining = true
                    Task {
                        if await model.joinTeam(fileId: link) { dismiss() }
                        joining = false
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(link.trimmingCharacters(in: .whitespaces).count < 10 || joining)
            }
            if let e = model.teamError {
                Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Tutup")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 520)
        .task { await model.refreshInvites() }
    }

    private func row<B: View>(_ n: Int, _ title: String, _ text: String, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 12, weight: .bold)).frame(width: 22, height: 22)
                .background(Theme.brandGradient, in: Circle()).foregroundStyle(.black.opacity(0.75))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            button()
        }
    }
}

private struct ShareHostsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let team: TeamInfo
    @State private var picked: Set<String> = []
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Host untuk {}", team.name)).font(.title3.bold())
            Text(L("Anggota bisa connect ke host ini (termasuk password & SSH key-nya), tapi tidak bisa mengubahnya."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.ownHosts) { h in
                        Button {
                            if picked.contains(h.id) { picked.remove(h.id) } else { picked.insert(h.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked.contains(h.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(picked.contains(h.id) ? Theme.accent : .secondary)
                                RoundedRectangle(cornerRadius: 4).fill(Color(hex: h.color)).frame(width: 6, height: 20)
                                Text(h.title).font(.system(size: 13, weight: .medium))
                                if let g = h.group, !g.isEmpty { Text(g).font(.system(size: 11)).foregroundStyle(.tertiary) }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 300)
            .background(Theme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Text(L("{} dipilih", picked.count)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L("Batal")) { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(saving ? L("Menyimpan…") : L("Simpan")) {
                    saving = true
                    Task {
                        await model.shareHosts(team, ids: Array(picked))
                        saving = false
                        dismiss()
                    }
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { picked = Set(team.sharedHostIds) }
    }
}
