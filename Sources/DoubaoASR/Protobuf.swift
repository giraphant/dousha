import Foundation

/// Minimal hand-rolled proto3 wire codec. Supports the two scalar wire types
/// needed by asr.proto (varint + length-delimited). No nested messages,
/// no fixed32/fixed64, no packed fields.
enum Wire {
    enum Error: Swift.Error {
        case truncated
        case unsupportedWireType(Int)
        case invalidVarint
    }

    enum Field {
        case varint(UInt64)
        case length(Data)
    }

    static func writeVarint(_ value: UInt64, into buf: inout Data) {
        var v = value
        while v >= 0x80 {
            buf.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        buf.append(UInt8(v))
    }

    static func writeTag(field: Int, type: Int, into buf: inout Data) {
        writeVarint(UInt64((field << 3) | type), into: &buf)
    }

    static func writeString(field: Int, _ s: String, into buf: inout Data) {
        guard !s.isEmpty else { return }   // proto3 omits default-valued scalars
        let bytes = Data(s.utf8)
        writeTag(field: field, type: 2, into: &buf)
        writeVarint(UInt64(bytes.count), into: &buf)
        buf.append(bytes)
    }

    static func writeBytes(field: Int, _ b: Data, into buf: inout Data) {
        guard !b.isEmpty else { return }
        writeTag(field: field, type: 2, into: &buf)
        writeVarint(UInt64(b.count), into: &buf)
        buf.append(b)
    }

    static func writeInt32(field: Int, _ v: Int32, into buf: inout Data) {
        guard v != 0 else { return }
        writeTag(field: field, type: 0, into: &buf)
        // proto3 int32: encoded as 10-byte varint when negative; we always pass non-negative values.
        writeVarint(UInt64(UInt32(bitPattern: v)), into: &buf)
    }

    static func readVarint(_ data: Data, at i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < data.count {
            let byte = data[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { throw Error.invalidVarint }
        }
        throw Error.truncated
    }

    /// Returns the last value seen for each field tag (proto3 semantics for non-repeated fields).
    static func decodeFields(_ data: Data) throws -> [Int: Field] {
        var i = 0
        var out: [Int: Field] = [:]
        while i < data.count {
            let tag = try readVarint(data, at: &i)
            let field = Int(tag >> 3)
            let wireType = Int(tag & 0x7)
            switch wireType {
            case 0:
                let v = try readVarint(data, at: &i)
                out[field] = .varint(v)
            case 2:
                let len = try readVarint(data, at: &i)
                let n = Int(len)
                guard i + n <= data.count else { throw Error.truncated }
                out[field] = .length(data.subdata(in: i..<(i + n)))
                i += n
            default:
                throw Error.unsupportedWireType(wireType)
            }
        }
        return out
    }
}
