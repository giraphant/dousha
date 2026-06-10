import Foundation

/// Minimal pure-Swift MD5 (RFC 1321).
///
/// Used ONLY for Doubao's `x-ss-stub` request header — a protocol checksum the
/// server expects, not a security boundary (the hashed body is the constant
/// "body=null"). Replaces CryptoKit's `Insecure.MD5` so DoubaoASR builds on
/// platforms without CryptoKit (Windows port, QUA-209). Verified against the
/// RFC 1321 test vectors and cross-checked against CryptoKit in
/// `InsecureMD5Tests`.
enum InsecureMD5 {
    /// Per-round left-rotate amounts.
    private static let s: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// K[i] = floor(2^32 × abs(sin(i + 1))) — the RFC 1321 constant table.
    private static let k: [UInt32] = (0..<64).map {
        UInt32((abs(sin(Double($0 + 1))) * 4294967296.0).rounded(.down))
    }

    static func digest(_ message: Data) -> [UInt8] {
        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe
        var d0: UInt32 = 0x1032_5476

        // Pad: 0x80, zeros to 56 mod 64, then original bit length as UInt64 LE.
        var padded = [UInt8](message)
        let bitLength = UInt64(message.count) &* 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 0, to: 64, by: 8) {
            padded.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            // 16 little-endian UInt32 words.
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let o = chunkStart + i * 4
                m[i] = UInt32(padded[o])
                    | UInt32(padded[o + 1]) << 8
                    | UInt32(padded[o + 2]) << 16
                    | UInt32(padded[o + 3]) << 24
            }

            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = i
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
            }
            a0 &+= a
            b0 &+= b
            c0 &+= c
            d0 &+= d
        }

        var out = [UInt8]()
        out.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            for shift in stride(from: 0, to: 32, by: 8) {
                out.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return out
    }

    /// Uppercase hex digest — the exact format Doubao's `x-ss-stub` expects.
    static func hexUpper(_ message: Data) -> String {
        digest(message).map { String(format: "%02X", $0) }.joined()
    }
}
