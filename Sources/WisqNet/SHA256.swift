import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Thin wrapper so call sites do not need a `#if canImport` of their own.
public enum SHA256 {
    public static func digest(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        // Only reached on platforms without CryptoKit; pinning is unavailable there.
        return Data()
        #endif
    }

    public static func fingerprintString(_ data: Data) -> String {
        digest(data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
