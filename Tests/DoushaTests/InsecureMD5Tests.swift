import XCTest
import CryptoKit
@testable import DoubaoASR

/// Guards the pure-Swift MD5 that replaced CryptoKit's `Insecure.MD5` for the
/// Windows port (QUA-209). Doubao's `x-ss-stub` header depends on this digest
/// being byte-identical to what the official client sends.
final class InsecureMD5Tests: XCTestCase {

    /// RFC 1321 §A.5 test vectors.
    func testRFC1321Vectors() {
        let vectors: [(String, String)] = [
            ("", "d41d8cd98f00b204e9800998ecf8427e"),
            ("a", "0cc175b9c0f1b6a831c399e269772661"),
            ("abc", "900150983cd24fb0d6963f7d28e17f72"),
            ("message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
            ("abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
            ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
             "d174ab98d277d9f5a5611c2c9f419d9f"),
            ("12345678901234567890123456789012345678901234567890123456789012345678901234567890",
             "57edf4a22be3c955ac49da2e2107b67a"),
        ]
        for (input, expected) in vectors {
            let got = InsecureMD5.digest(Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(got, expected, "MD5(\(input.debugDescription))")
        }
    }

    /// The exact production input: the `x-ss-stub` header hashes "body=null".
    func testMatchesCryptoKitOnProductionInput() {
        let body = Data("body=null".utf8)
        let reference = Insecure.MD5.hash(data: body).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(InsecureMD5.hexUpper(body), reference)
    }

    /// Padding edge cases: lengths around the 56-byte / 64-byte block
    /// boundaries, cross-checked against CryptoKit.
    func testMatchesCryptoKitAroundBlockBoundaries() {
        for length in [55, 56, 57, 63, 64, 65, 119, 120, 128, 1000] {
            let data = Data((0..<length).map { UInt8($0 % 251) })
            let reference = Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
            XCTAssertEqual(InsecureMD5.hexUpper(data), reference, "length \(length)")
        }
    }
}
