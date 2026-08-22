#if os(macOS) || os(Linux)
import Foundation
import WisqCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Everything the daemon prints at startup so a phone can find and trust it.
public enum Pairing {
    /// Non-loopback IPv4 addresses of this host, one per interface.
    public static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }

        var cursor = interfaces
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                address, socklen_t(MemoryLayout<sockaddr_in>.size),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }

            let text = String(cString: host)
            if text != "127.0.0.1", !text.isEmpty {
                addresses.append(text)
            }
        }
        return addresses
    }

    /// One pairing URL per reachable address, hostname first when it resolves.
    public static func urls(port: UInt16, token: String, hostName: String? = nil) -> [URL] {
        var hosts = localIPv4Addresses()
        if let hostName, !hostName.isEmpty {
            hosts.insert(hostName, at: 0)
        }
        return hosts.compactMap { host in
            AgentPairing.url(for: AgentPairing.Payload(
                host: host, port: Int(port), token: token, name: hostName
            ))
        }
    }

    /// Renders a QR code in the terminal when `qrencode` is installed; quietly
    /// does nothing otherwise. A missing nicety must never break the daemon.
    public static func printQRCodeIfPossible(for url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["qrencode", "-t", "ANSIUTF8", url.absoluteString]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // qrencode absent: the URL alone is enough to pair.
        }
    }
}

/// Advertises the agent over mDNS so the app can list it without any typing.
///
/// Best effort through the platform's own tool — `dns-sd` on macOS,
/// `avahi-publish-service` on Linux — because linking a DNS-SD stack for a
/// nicety would be backwards. If neither exists, discovery simply stays manual.
public final class BonjourAdvertiser: @unchecked Sendable {
    public static let serviceType = "_wisq-agent._tcp"

    private var process: Process?

    public init() {}

    public func start(port: UInt16, name: String) {
        let candidates: [[String]] = [
            ["avahi-publish-service", name, Self.serviceType, String(port)],
            ["dns-sd", "-R", name, Self.serviceType, "local", String(port)],
        ]
        for arguments in candidates {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                self.process = process
                return
            } catch {
                continue
            }
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
    }
}
#endif
