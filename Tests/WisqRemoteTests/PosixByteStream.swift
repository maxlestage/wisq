#if canImport(Glibc)
import Foundation
import Glibc
import WisqCore
import WisqNet

/// Un `ByteStream` sur une vraie socket, pour les tests seulement.
///
/// **Pourquoi il vit ici et pas dans `WisqNet`.** Le transport de production
/// est `NetworkByteStream`, bâti sur le cadre `Network` d'Apple, parce que
/// l'application est une application iOS. Il ne se construit donc pas sur ce
/// conteneur Linux — et c'est exactement là que tourne le seul vrai serveur RDP
/// qu'on ait. Cette pièce-ci comble ce trou, et rien d'autre : elle n'est
/// compilée que par les tests, sur Linux, et aucun chemin de l'application ne
/// la voit.
actor PosixByteStream: ByteStream {
    /// Ce que lève une lecture qui a atteint son délai sans rien recevoir. Le
    /// serveur est là, il n'a simplement plus rien à dire.
    struct Quiet: Error {}

    private var descriptor: Int32 = -1

    /// `readTimeout` est en secondes. Cinq par défaut, parce qu'un test qui
    /// attend un message que le serveur n'enverra jamais bloque la suite
    /// entière ; plus court quand le test veut au contraire *constater* que
    /// plus rien n'arrive.
    init(host: String, port: Int, readTimeout: Int = 5) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw WisqError.connectionFailed("adresse « \(host) » introuvable")
        }
        defer { freeaddrinfo(list) }
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let candidate = node {
            let socketDescriptor = socket(candidate.pointee.ai_family,
                                          candidate.pointee.ai_socktype,
                                          candidate.pointee.ai_protocol)
            if socketDescriptor >= 0 {
                if connect(socketDescriptor, candidate.pointee.ai_addr,
                           candidate.pointee.ai_addrlen) == 0 {
                    // **Une lecture qui n'aboutit pas doit échouer, pas
                    // pendre.** Un test qui attend un message que le serveur
                    // n'enverra jamais bloque la suite entière, et rien
                    // n'indique lequel.
                    var limit = timeval(tv_sec: readTimeout, tv_usec: 0)
                    setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO,
                               &limit, socklen_t(MemoryLayout<timeval>.size))
                    descriptor = socketDescriptor
                    return
                }
                Glibc.close(socketDescriptor)
            }
            node = candidate.pointee.ai_next
        }
        throw WisqError.connectionFailed("\(host):\(port) n'a pas répondu")
    }

    func read(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: count)
        var filled = 0
        while filled < count {
            var failure: Int32 = 0
            let got = out.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                let result = recv(descriptor, base + filled, count - filled, 0)
                if result < 0 { failure = errno }
                return result
            }
            // **Un délai dépassé n'est pas une connexion fermée**, et les
            // confondre fait prendre un serveur qui n'a rien à dire pour un
            // serveur qui a raccroché — ce qui est précisément la différence
            // que mesurent les tests d'entrées.
            if got < 0, failure == EAGAIN || failure == EWOULDBLOCK {
                throw PosixByteStream.Quiet()
            }
            guard got > 0 else { throw WisqError.connectionClosed }
            filled += got
        }
        return Data(out)
    }

    func write(_ data: Data) async throws {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let wrote = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return send(descriptor, base + sent, bytes.count - sent, 0)
            }
            guard wrote > 0 else { throw WisqError.connectionClosed }
            sent += wrote
        }
    }

    func close() {
        if descriptor >= 0 { Glibc.close(descriptor) }
        descriptor = -1
    }
}
#endif
