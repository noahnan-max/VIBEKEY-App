import Foundation

public enum DeviceHandshake {
    private static let replyMasks: [UInt32] = [0x20141107,0xc138bf6d,0xa8ab23c7,0x73165329,0x30629139,0xd9f4e04c,0xec8c35bf,0x64101856,0x47201988,0x98211053,0xf0d4eca9,0x82991136,0x09153583,0x16141925,0xbf8a7ced,0x54557049]
    public static func request(challenge: UInt32) -> Data {
        var frame = Data([6, 2, 5, 1, UInt8(challenge & 15)])
        for n in 0..<4 { frame.append(UInt8(truncatingIfNeeded: challenge >> (8 * n))) }
        frame.append(Data(repeating: 0, count: 64 - frame.count)); return frame
    }
    public static func accepts(_ decoded: Data, challenge: UInt32) -> Bool {
        let b = [UInt8](decoded)
        guard b.count >= 9, b[0] & 31 == 6, b[1] & 15 == 2, b[2] == 5, b[3] & 16 != 0, b[4] < 16 else { return false }
        let encoded = UInt32(b[5]) | UInt32(b[6]) << 8 | UInt32(b[7]) << 16 | UInt32(b[8]) << 24
        return encoded ^ replyMasks[Int(b[4])] == challenge
    }
    public static var heartbeat: Data { Data([6, 1, 0x23, 0, 1]) + Data(repeating: 0, count: 59) }
}
