#if os(macOS) || os(Linux)
import Foundation
import XCTest

/// Runs the real `wisq-agent` binary for a test to talk to.
///
/// The daemon is Rust and the client is Swift, so the only place the two halves
/// of the protocol can be checked against each other is a test that runs both.
/// A Swift stand-in server would test the wire format twice against itself and
/// prove nothing about what actually ships.
///
/// The binary is not built by SwiftPM; `cargo build` produces it, and CI does
/// that before running the suite. When it is missing these tests skip loudly
/// rather than failing and blaming the protocol.
final class RustAgentProcess {
    let baseURL: URL
    let token = "secret-token"
    private let process: Process

    static func binaryPath() -> String? {
        let candidates: [String?] = [
            ProcessInfo.processInfo.environment["WISQ_AGENT_BINARY"],
            packageRoot().appendingPathComponent("target/release/wisq-agent").path,
            packageRoot().appendingPathComponent("target/debug/wisq-agent").path,
        ]
        for case let path? in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func packageRoot() -> URL {
        // Tests/WisqAgentTests/RustAgentProcess.swift → the package directory.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Starts the daemon on an ephemeral port and waits until it says which one.
    ///
    /// Plain HTTP by default: the protocol tests exercise routes and JSON, and
    /// URLSession on Linux cannot override trust for a self-signed certificate.
    /// `tls: true` starts the daemon as it really ships, for the tests that
    /// check the pairing link carries the certificate story.
    init(demoDelayMilliseconds: Int = 50, tls: Bool = false) throws {
        guard let binary = Self.binaryPath() else {
            throw XCTSkip("wisq-agent absent : lancez `cargo build --release` d'abord")
        }

        process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = [
            "--demo",
            "--demo-delay", String(demoDelayMilliseconds),
            "--port", "0",
            "--token", token,
        ]
        if !tls {
            arguments.append("--no-tls")
        }
        process.arguments = arguments
        // A private HOME so a test never reads or writes the developer's own
        // pairing token.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = NSTemporaryDirectory() + "wisq-agent-tests-\(UUID().uuidString)"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        // The port is whatever the OS gave it, and the daemon prints it. Reading
        // the whole startup block back also keeps the pairing lines under test:
        // they are what a person copies into the app.
        guard let startup = Self.readStartup(from: output.fileHandleForReading),
              let port = startup.port else {
            process.terminate()
            throw WisqAgentTestError.noPortAnnounced
        }
        startupOutput = startup.text
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    /// Everything the daemon printed before it began serving.
    private(set) var startupOutput = ""

    /// The `wisq://` links the daemon offered for pairing.
    var pairingURLs: [URL] {
        startupOutput
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("wisq://") }
            .compactMap(URL.init(string:))
    }

    private static func readStartup(from handle: FileHandle) -> (port: Int?, text: String)? {
        var buffer = ""
        var port: Int?
        let deadline = Date().addingTimeInterval(10)

        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            buffer += String(decoding: chunk, as: UTF8.self)

            if port == nil {
                for line in buffer.split(separator: "\n") where line.contains("en écoute sur le port") {
                    port = line.split(separator: " ").compactMap { Int($0) }.first
                }
            }
            // The startup block is printed in one go; once the port and at least
            // one pairing line have arrived there is nothing more to wait for.
            if port != nil, buffer.contains("wisq://") {
                return (port, buffer)
            }
        }
        return port.map { ($0, buffer) }
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
    }
}

enum WisqAgentTestError: Error {
    case noPortAnnounced
}
#endif
