import Foundation

extension Error {
    /// Pesan error yang enak dibaca (bukan nama enum dari binding UniFFI), dalam bahasa aktif.
    var ztermMessage: String {
        guard let e = self as? CoreError else { return Lmsg(localizedDescription) }
        switch e {
        case .WrongPassword: return L("Master password salah")
        case .AlreadyExists: return L("Data sudah ada")
        case .NotFound: return L("Data tidak ditemukan")
        case .WeakPassword: return L("Password minimal 8 karakter")
        case .KeyMismatch: return L("Vault di Google Drive memakai master password lain")
        case .InvalidKey(let msg): return L("SSH key tidak valid: {}", Lmsg(msg))
        case .Corrupt(let msg): return L("File vault rusak: {}", Lmsg(msg))
        case .Ssh(let msg): return L("Koneksi SSH gagal: {}", Lmsg(msg))
        case .Proxy(let msg): return L("Proxy: {}", Lmsg(msg))
        case .AuthFailed: return L("Login ditolak server — periksa username, password, atau key")
        case .HostKeyChanged: return L("Kunci server berubah! Hapus host ini di Known Hosts jika memang server berganti.")
        case .Db(let msg): return L("Database: {}", Lmsg(msg))
        case .Cancelled: return L("Dibatalkan")
        case .Io(let msg): return L("Gagal membaca/menulis file: {}", Lmsg(msg))
        case .GoogleAuth: return L("Sesi Google berakhir. Masuk lagi dengan Google untuk melanjutkan.")
        case .GoogleScope: return L("Zterm belum diberi izin mengelola file Tim di Google Drive. Masuk ulang dengan Google dan izinkan akses Drive.")
        case .Team(let msg): return L("Tim: {}", Lmsg(msg))
        case .Docker(let msg): return Lmsg(msg.prefix(1).uppercased() + msg.dropFirst())
        case .Stack(let msg): return Lmsg(msg.prefix(1).uppercased() + msg.dropFirst())
        case .Server(let msg): return Lmsg(msg.prefix(1).uppercased() + msg.dropFirst())
        }
    }
}
