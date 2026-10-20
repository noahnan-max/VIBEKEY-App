import Foundation

public enum AU05Codec {
    // Transport constants recovered from MessageHelper encodeMessage (SDK 0x1f0a8).
    // These fixed protocol words are not account credentials or device identity.
    private static let key: [UInt32] = [0xcaa5baca, 0xbc2a8a6d, 0xca5a9eba, 0x9bb88bca]

    public static func tea(_ data: Data, decrypt: Bool) -> Data {
        precondition(data.count % 8 == 0)
        let bytes = [UInt8](data)
        var output = Data()
        for offset in stride(from: 0, to: bytes.count, by: 8) {
            func word(_ i: Int) -> UInt32 {
                UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            }
            var left = word(offset), right = word(offset + 4)
            var sum: UInt32 = decrypt ? 0xc6ef3720 : 0
            for _ in 0..<32 {
                if decrypt {
                    right &-= ((left << 4) &+ key[2]) ^ (left &+ sum) ^ ((left >> 5) &+ key[3])
                    left &-= ((right << 4) &+ key[0]) ^ (right &+ sum) ^ ((right >> 5) &+ key[1])
                    sum &-= 0x9e3779b9
                } else {
                    sum &+= 0x9e3779b9
                    left &+= ((right << 4) &+ key[0]) ^ (right &+ sum) ^ ((right >> 5) &+ key[1])
                    right &+= ((left << 4) &+ key[2]) ^ (left &+ sum) ^ ((left >> 5) &+ key[3])
                }
            }
            for value in [left, right] {
                output.append(UInt8(truncatingIfNeeded: value))
                output.append(UInt8(truncatingIfNeeded: value >> 8))
                output.append(UInt8(truncatingIfNeeded: value >> 16))
                output.append(UInt8(truncatingIfNeeded: value >> 24))
            }
        }
        return output
    }

    public static func outputReport(plaintext: Data) throws -> Data {
        guard plaintext.count == 64 else { throw TransportError.invalidReport }
        var report = Data([0x55])
        report.append(tea(plaintext, decrypt: false).prefix(63))
        return report
    }

    public static func decodeReport(_ report: Data) -> Data? {
        guard report.count == 64, report.first == 0x55 else { return nil }
        // The HID report has only 63 ciphertext bytes. Only the first seven full
        // TEA blocks (56 bytes) are recoverable; never invent the last block.
        return tea(Data(report.dropFirst().prefix(56)), decrypt: true)
    }

    public static func readFrame(group: UInt8, command: UInt8, payload: [UInt8] = [], frameType: UInt8 = 1) -> Data {
        var frame = Data([frameType, group, command, 0x01])
        frame.append(contentsOf: payload.prefix(52))
        frame.append(Data(repeating: 0, count: 64 - frame.count))
        return frame
    }
}
