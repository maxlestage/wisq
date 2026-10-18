import Foundation

/// Le CRC-32 d'IEEE 802.3, celui de zlib, de PNG et de la table de partitions
/// GPT : polynôme 0x04C11DB7 lu à l'envers (0xEDB88320), valeur initiale et
/// finale inversées.
///
/// Écrit ici plutôt que pris à zlib pour la même raison que `Inflate` :
/// `WisqVM` ne dépend que de Foundation. Une table de 256 mots, calculée une
/// fois ; la GPT n'en demande que quelques kilo-octets par disque, la vitesse
/// n'est pas l'enjeu.
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    /// La somme de `bytes`.
    public static func checksum<Bytes: Sequence>(_ bytes: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}
