import SwiftUI

/// Background beranimasi bersama untuk welcome, buat password, dan lock screen.
struct OnboardingContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AnimatedBackground()
            Group {
                switch model.phase {
                case .welcome: WelcomeView().transition(.blurSlide)
                case .createPassword: CreatePasswordView().transition(.blurSlide)
                case .restore: RestoreView().transition(.blurSlide)
                case .locked: LockView().transition(.blurSlide)
                case .main: Color.clear
                }
            }
            .frame(width: 420)
        }
        .overlay(alignment: .topTrailing) {
            AppearanceMenu().padding(16).foregroundStyle(.secondary)
        }
        .animation(.zterm, value: model.phase)
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ZtermLogo(size: 84)
                .staggerIn(0, base: 0.1)
                .padding(.bottom, 28)

            Text(L("Selamat datang di Zterm"))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .staggerIn(1, base: 0.1)

            TypewriterText(L("Semua servermu, satu terminal."), delay: 0.7)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
                .frame(height: 24)

            VStack(spacing: 12) {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack(spacing: 10) {
                        if signingIn { ProgressView().controlSize(.small).tint(.black) }
                        else { GoogleMark().frame(width: 18, height: 18) }
                        Text(L("Masuk dengan Google"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle(wide: true, size: .large))
                .disabled(signingIn)
                .staggerIn(3, base: 0.6)

                Button(L("Pakai tanpa akun")) {
                    model.pendingAccountEmail = nil
                    model.phase = .createPassword
                }
                .buttonStyle(SecondaryButtonStyle(wide: true, size: .large))
                .staggerIn(4, base: 0.6)

                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.top, 40)

            Label(L("Data host dienkripsi di perangkatmu. Login Google hanya untuk sync lewat Google Drive milikmu."),
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 28)
                .staggerIn(5, base: 0.6)
        }
        .animation(.zterm, value: error)
    }

    private func signIn() async {
        signingIn = true
        defer { signingIn = false }
        do {
            let needsRestore = try await model.signInGoogle()
            model.phase = needsRestore ? .restore : .createPassword
        } catch GoogleAuth.AuthError.cancelled {
        } catch {
            self.error = Lmsg(error.localizedDescription)
        }
    }
}

/// Logo "G" sederhana (empat warna) — digambar sendiri.
struct GoogleMark: View {
    var body: some View {
        ZStack {
            Circle().trim(from: 0.0, to: 0.25).stroke(Color(hex: "#EA4335"), lineWidth: 3.2)
            Circle().trim(from: 0.25, to: 0.5).stroke(Color(hex: "#FBBC05"), lineWidth: 3.2)
            Circle().trim(from: 0.5, to: 0.75).stroke(Color(hex: "#34A853"), lineWidth: 3.2)
            Circle().trim(from: 0.75, to: 0.97).stroke(Color(hex: "#4285F4"), lineWidth: 3.2)
        }
        .rotationEffect(.degrees(-45))
        .padding(2)
        .background(.white, in: Circle())
    }
}

// MARK: - Buat master password

struct CreatePasswordView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shake = 0
    @FocusState private var focus: Int?

    private var strength: Int {
        var s = 0
        if password.count >= 8 { s += 1 }
        if password.count >= 12 { s += 1 }
        if password.rangeOfCharacter(from: .decimalDigits) != nil { s += 1 }
        if password.rangeOfCharacter(from: .punctuationCharacters.union(.symbols)) != nil
            || password.rangeOfCharacter(from: .uppercaseLetters) != nil { s += 1 }
        return s
    }

    private var valid: Bool { password.count >= 8 && password == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.phase = .welcome
            } label: {
                Label(L("Kembali"), systemImage: "chevron.left").font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)

            Image(systemName: "lock.rotation")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.brandGradient)
                .symbolEffect(.bounce, value: valid)
                .staggerIn(0, base: 0.05)

            Text(L("Buat master password"))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 16)
                .staggerIn(1, base: 0.05)

            Group {
                if let email = model.pendingAccountEmail {
                    Text(LocalizedStringKey(L("Masuk sebagai **{}**. ", email)))
                        + Text(L("Password ini mengunci vault-mu dan tidak pernah dikirim ke Google."))
                } else {
                    Text(L("Password ini mengunci semua host dan SSH key di perangkat ini."))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .staggerIn(2, base: 0.05)

            VStack(spacing: 10) {
                SecureField(L("Master password (min. 8 karakter)"), text: $password)
                    .focused($focus, equals: 0)
                    .onSubmit { focus = 1 }
                    .ztermField()
                StrengthBar(level: strength)
                SecureField(L("Ulangi password"), text: $confirm)
                    .focused($focus, equals: 1)
                    .onSubmit { Task { await submit() } }
                    .ztermField(error: !confirm.isEmpty && confirm != password)
            }
            .padding(.top, 24)
            .modifier(Shake(trigger: shake))
            .staggerIn(3, base: 0.05)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.top, 8)
            }

            Button {
                Task { await submit() }
            } label: {
                HStack {
                    if busy { ProgressView().controlSize(.small).tint(.black) }
                    Text(busy ? L("Membuat vault…") : L("Buat vault & mulai"))
                }
            }
            .buttonStyle(PrimaryButtonStyle(wide: true, size: .large))
            .disabled(!valid || busy)
            .padding(.top, 24)
            .staggerIn(4, base: 0.05)

            Label(L("Tidak bisa dipulihkan jika lupa. Simpan di tempat aman."), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
                .staggerIn(5, base: 0.05)
        }
        .onAppear { focus = 0 }
        .animation(.zterm, value: strength)
    }

    private func submit() async {
        guard valid else { withAnimation(.default) { shake += 1 }; return }
        busy = true
        defer { busy = false }
        do { try await model.createVault(password: password) }
        catch { self.error = Lmsg(error.localizedDescription); withAnimation(.default) { shake += 1 } }
    }
}

struct StrengthBar: View {
    let level: Int
    private let labels = [L("Terlalu pendek"), L("Lemah"), L("Cukup"), L("Kuat"), L("Sangat kuat")]
    private var color: Color { [Color.red, .orange, .yellow, Theme.accent, Theme.accent][level] }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<4) { i in
                    Capsule()
                        .fill(i < level ? color : Theme.ink.opacity(0.1))
                        .frame(height: 4)
                }
            }
            Text(labels[level]).font(.caption2).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }
    }
}

// MARK: - Pulihkan dari Google Drive

struct RestoreView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shake = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.15)).frame(width: 84, height: 84)
                Image(systemName: "icloud.and.arrow.down.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                    .symbolEffect(.bounce, options: .repeat(.periodic(delay: 2)))
            }
            .staggerIn(0, base: 0.05)
            .padding(.bottom, 22)

            Text(L("Vault ditemukan di Google Drive"))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .staggerIn(1, base: 0.05)
            Text(L("Masukkan master password yang kamu pakai di perangkat lain untuk memulihkan host dan SSH key."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 6)
                .staggerIn(2, base: 0.05)

            HStack(spacing: 10) {
                SecureField(L("Master password"), text: $password)
                    .focused($focused)
                    .onSubmit { Task { await submit() } }
                    .ztermField(error: error != nil)
                Button {
                    Task { await submit() }
                } label: {
                    Group {
                        if busy { ProgressView().controlSize(.small).tint(.black) }
                        else { Image(systemName: "arrow.right") }
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(PrimaryButtonStyle(size: .large))
                .disabled(password.isEmpty || busy)
            }
            .modifier(Shake(trigger: shake))
            .padding(.top, 26)
            .staggerIn(3, base: 0.05)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.top, 10).transition(.opacity)
            }

            Button(L("Mulai vault baru saja")) {
                model.pendingRemoteBlob = nil
                model.phase = .createPassword
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 18)
            .staggerIn(4, base: 0.05)
        }
        .onAppear { focused = true }
        .animation(.zterm, value: error)
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        do { try await model.restore(password: password) }
        catch {
            self.error = L("Master password salah")
            password = ""
            withAnimation(.default) { shake += 1 }
        }
    }
}

// MARK: - Lock screen

struct LockView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var shake = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZtermLogo(size: 72).staggerIn(0, base: 0.05).padding(.bottom, 24)

            Text(L("Vault terkunci"))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .staggerIn(1, base: 0.05)
            Text(L("Masukkan master password untuk melanjutkan."))
                .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                .staggerIn(2, base: 0.05)

            HStack(spacing: 10) {
                SecureField(L("Master password"), text: $password)
                    .focused($focused)
                    .onSubmit { Task { await unlock() } }
                    .ztermField(error: error != nil)
                Button {
                    Task { await unlock() }
                } label: {
                    Group {
                        if busy { ProgressView().controlSize(.small).tint(.black) }
                        else { Image(systemName: "arrow.right") }
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(PrimaryButtonStyle(size: .large))
                .disabled(password.isEmpty || busy)
            }
            .modifier(Shake(trigger: shake))
            .padding(.top, 28)
            .staggerIn(3, base: 0.05)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.top, 10)
                    .transition(.opacity)
            }

            if BiometricUnlock.isAvailable {
                Button {
                    Task { await biometric() }
                } label: {
                    Label(L("Buka dengan Touch ID"), systemImage: "touchid")
                }
                .buttonStyle(SecondaryButtonStyle(wide: true, size: .large))
                .padding(.top, 14)
                .staggerIn(4, base: 0.05)
            }
        }
        .onAppear {
            focused = true
            // Hanya saat benar-benar terkunci (bukan saat layar ini sedang memudar keluar)
            if model.phase == .locked && BiometricUnlock.isAvailable { Task { await biometric() } }
        }
        .animation(.zterm, value: error)
    }

    private func unlock() async {
        busy = true
        defer { busy = false }
        do { try await model.unlock(password: password) }
        catch {
            self.error = Lmsg(error.localizedDescription)
            password = ""
            withAnimation(.default) { shake += 1 }
        }
    }

    private func biometric() async {
        guard model.phase == .locked else { return }
        try? await model.unlockWithBiometrics()
    }
}

// MARK: - Helpers

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    init(trigger: Int) { animatableData = CGFloat(trigger) }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 8 * sin(animatableData * .pi * 6), y: 0))
    }
}

struct ZtermField: ViewModifier {
    var error = false
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(error ? Color.red.opacity(0.7) : Theme.ink.opacity(0.1))
            )
    }
}

extension View {
    func ztermField(error: Bool = false) -> some View { modifier(ZtermField(error: error)) }
}
