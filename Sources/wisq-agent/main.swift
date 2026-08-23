#if os(macOS) || os(Linux)
import Foundation
import WisqAgentKit
import WisqCore
/// Unbuffered stdout: a daemon's startup lines must reach journald or a log
/// file as they happen, not when a stdio buffer fills. `print` buffers when
/// stdout is a pipe; a direct FileHandle write does not.
func emit(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

// wisq-agent: the daemon that lets the phone power VMs on before connecting.
//
//   wisq-agent                     libvirt via virsh, port 7442
//   wisq-agent --demo              two fake VMs, for trying the app
//   wisq-agent --port 9000
//   wisq-agent --token SECRET      (otherwise generated and persisted)

var port: UInt16 = 7442
var token: String?
var useDemo = false
var virshPath = "/usr/bin/virsh"

var arguments = ArraySlice(CommandLine.arguments.dropFirst())
while let argument = arguments.popFirst() {
    switch argument {
    case "--port":
        guard let value = arguments.popFirst(), let parsed = UInt16(value) else {
            FileHandle.standardError.write(Data("--port attend un nombre entre 1 et 65535\n".utf8))
            exit(2)
        }
        port = parsed
    case "--token":
        token = arguments.popFirst()
    case "--demo":
        useDemo = true
    case "--virsh":
        virshPath = arguments.popFirst() ?? virshPath
    case "--help", "-h":
        emit("""
        wisq-agent [--port N] [--token SECRET] [--demo] [--virsh CHEMIN]

        Sert le protocole décrit dans docs/AGENT-PROTOCOL.md. Sans --token, un
        jeton est généré au premier lancement et conservé dans ~/.wisq-agent/token.
        """)
        exit(0)
    default:
        FileHandle.standardError.write(Data("argument inconnu : \(argument)\n".utf8))
        exit(2)
    }
}

// Token: explicit beats stored beats generated. The generated one persists so
// the pairing survives daemon restarts.
let resolvedToken: String
if let token {
    resolvedToken = token
} else {
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".wisq-agent", isDirectory: true)
    let file = directory.appendingPathComponent("token")
    if let stored = try? String(contentsOf: file, encoding: .utf8),
       !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        resolvedToken = stored.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        let generated = (0..<32).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
        resolvedToken = String(generated)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? resolvedToken.write(to: file, atomically: true, encoding: .utf8)
        #if canImport(Glibc)
        chmod(file.path, 0o600)
        #endif
    }
}

let backend: any VMBackend = useDemo ? DemoBackend() : VirshBackend(virshPath: virshPath)
let service = AgentService(backend: backend, token: resolvedToken)
let server = HTTPServer { service.handle($0) }

do {
    try server.start(port: port)
} catch {
    FileHandle.standardError.write(Data("démarrage impossible : \(error)\n".utf8))
    exit(1)
}

let hostName = ProcessInfo.processInfo.hostName
emit("""
wisq-agent en écoute sur le port \(server.port) (\(useDemo ? "démo" : "virsh"))
jeton : \(resolvedToken)
""")

// Pairing: one URL per reachable address; the app's "Importer depuis un agent"
// screen opens pre-filled from any of them, and the QR carries the first.
let pairingURLs = Pairing.urls(port: server.port, token: resolvedToken, hostName: hostName)
if !pairingURLs.isEmpty {
    emit("appairage :")
    for url in pairingURLs {
        emit("  \(url.absoluteString)")
    }
    emit("")
    Pairing.printQRCodeIfPossible(for: pairingURLs[0])
}

let advertiser = BonjourAdvertiser()
// The service name doubles as the address: mDNS makes host "nas" reachable at
// nas.local, so the app can offer "<name>.local" without resolving SRV records.
advertiser.start(port: server.port, name: hostName)

dispatchMain()
#endif
