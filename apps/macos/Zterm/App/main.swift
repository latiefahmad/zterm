import Foundation

// Mode ProxyCommand: `ssh -o ProxyCommand="<app> --zterm-proxy <socks5|http> <proxy-host> <proxy-port> %h %p"`.
// Proses ini hanya menyalurkan stdin/stdout ke server lewat proxy, tanpa membuka UI.
let arguments = CommandLine.arguments
if arguments.count >= 7, arguments[1] == "--zterm-proxy" {
    let env = ProcessInfo.processInfo.environment
    let proxy = HostProxy(kind: arguments[2] == "http" ? .http : .socks5,
                          host: arguments[3], port: UInt16(arguments[4]) ?? 1080,
                          username: env["ZTERM_PROXY_USER"], password: env["ZTERM_PROXY_PASS"])
    do {
        try proxyStdio(proxy: proxy, host: arguments[5], port: UInt16(arguments[6]) ?? 22)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Zterm: \(error.ztermMessage)\n".utf8))
        exit(1)
    }
}

ZtermApp.main()
