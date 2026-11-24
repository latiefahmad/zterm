import Foundation
import SwiftUI

/// Menjalankan aturan port forwarding sebagai proses `ssh -N` di latar belakang.
@MainActor
@Observable
final class TunnelManager {
    enum State: Equatable { case starting, running, failed(String) }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var processes: [String: Process] = [:]
    @ObservationIgnored private var tempFiles: [String: [URL]] = [:]

    func isRunning(_ id: String) -> Bool {
        switch states[id] { case .starting, .running: true; default: false }
    }

    func start(_ f: PortForward, host: Host, key: SshKey?, jump: Host?) {
        let spec: [String]
        switch f.kind {
        case .local: spec = ["-L", "\(f.bindAddress):\(f.bindPort):\(f.destHost):\(f.destPort)"]
        case .remote: spec = ["-R", "\(f.bindAddress):\(f.bindPort):\(f.destHost):\(f.destPort)"]
        case .dynamic: spec = ["-D", "\(f.bindAddress):\(f.bindPort)"]
        }
        let cmd = SSHCommand(host: host, key: key, jump: jump,
                             extra: ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=no"] + spec)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = cmd.args
        p.environment = Dictionary(uniqueKeysWithValues: cmd.environment.compactMap { line -> (String, String)? in
            guard let i = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<i]), String(line[line.index(after: i)...]))
        })
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let id = f.id
        p.terminationHandler = { proc in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .split(separator: "\n").last.map(String.init) ?? ""
            Task { @MainActor in self.ended(id, code: proc.terminationStatus, message: err) }
        }
        do {
            try p.run()
            processes[id] = p
            tempFiles[id] = cmd.tempFiles
            withAnimation(.zterm) { states[id] = .starting }
            // Jika setelah 2,5 detik proses masih hidup, tunnel dianggap aktif.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.processes[id]?.isRunning == true { withAnimation(.zterm) { self?.states[id] = .running } }
            }
        } catch {
            states[id] = .failed(Lmsg(error.localizedDescription))
        }
    }

    func stop(_ id: String) {
        processes[id]?.terminate()
        processes[id] = nil
        cleanup(id)
        withAnimation(.zterm) { states[id] = nil }
    }

    func stopAll() { processes.keys.forEach(stop) }

    private func ended(_ id: String, code: Int32, message: String) {
        guard processes[id] != nil else { return } // dihentikan manual
        processes[id] = nil
        cleanup(id)
        withAnimation(.zterm) { states[id] = .failed(message.isEmpty ? L("ssh keluar dengan kode {}", code) : Lmsg(message)) }
    }

    private func cleanup(_ id: String) {
        tempFiles[id]?.forEach { try? FileManager.default.removeItem(at: $0) }
        tempFiles[id] = nil
    }
}
