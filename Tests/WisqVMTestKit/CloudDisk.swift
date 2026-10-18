import Foundation

/// Un disque brut comme `fdisk` le pose : un MBR à une seule partition, qui
/// commence au secteur 2048, et `volume` dedans. De quoi faire d'un système
/// de fichiers des fixtures une image de cloud.
public enum CloudDisk {
    public static func raw(around volume: [UInt8], type: UInt8 = 0x83) -> [UInt8] {
        var disk = [UInt8](repeating: 0, count: 2048 * 512)
        func le32(_ value: Int, at offset: Int) {
            for index in 0..<4 { disk[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
        }
        disk[446 + 4] = type
        le32(2048, at: 446 + 8)
        le32(volume.count / 512, at: 446 + 12)
        disk[510] = 0x55
        disk[511] = 0xAA
        return disk + volume
    }
}
