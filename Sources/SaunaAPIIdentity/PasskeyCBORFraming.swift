import Foundation

/// Framing limits for this verifier's deliberately narrow none-attestation and
/// ES256 COSE formats, before passing input to the existing CBOR decoder.
/// Arrays, tags, simple values and indefinite lengths are unsupported here.
func validatePasskeyCBORFraming(_ bytes: [UInt8]) throws {
    guard !bytes.isEmpty, bytes.count <= 65_536 else { throw PasskeyVerificationError.rejected }
    var frame = PasskeyCBORFrame(bytes: bytes)
    try frame.item(depth: 0)
    guard frame.position == bytes.count else { throw PasskeyVerificationError.rejected }
}

private struct PasskeyCBORFrame {
    let bytes: [UInt8]
    var position = 0
    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw PasskeyVerificationError.rejected }
        defer { position += 1 }
        return bytes[position]
    }
    mutating func argument(_ info: UInt8) throws -> UInt64 {
        if info < 24 { return UInt64(info) }
        let count: Int
        switch info {
        case 24: count = 1
        case 25: count = 2
        case 26: count = 4
        case 27: count = 8
        default: throw PasskeyVerificationError.rejected
        }
        guard count <= bytes.count - position else { throw PasskeyVerificationError.rejected }
        var value: UInt64 = 0
        for _ in 0..<count { value = value << 8 | UInt64(try byte()) }
        return value
    }
    mutating func item(depth: Int) throws {
        guard depth <= 16 else { throw PasskeyVerificationError.rejected }
        let header = try byte()
        let major = header >> 5
        guard [UInt8(0), 1, 2, 3, 5].contains(major) else { throw PasskeyVerificationError.rejected }
        let size = try argument(header & 0x1f)
        switch major {
        case 0, 1: return // scalar integers allocate no input-dependent containers
        case 2, 3:
            guard size <= UInt64(bytes.count - position) else { throw PasskeyVerificationError.rejected }
            position += Int(size)
        case 5:
            // Supported objects have at most five entries; allow a small margin
            // while bounding both encoded children and decoder container sizes.
            guard size <= 16, size <= UInt64((bytes.count - position) / 2) else { throw PasskeyVerificationError.rejected }
            for _ in 0..<(Int(size) * 2) { try item(depth: depth + 1) }
        default: throw PasskeyVerificationError.rejected
        }
    }
}
