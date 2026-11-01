package import Foundation

/// Foundation validates JSON syntax; this bounded companion rejects duplicate
/// object properties after decoding their escaped names with the same decoder.
/// It does not interpret authentication fields or replace JSONDecoder.
func rejectDuplicateJSONProperties(_ data: Data, maximumBytes: Int = 65_536) throws {
    guard !data.isEmpty, data.count <= maximumBytes else { throw PasskeyVerificationError.invalidInput }
    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    var scanner = UniqueJSONProperties(bytes: Array(data))
    try scanner.value(depth: 0)
    scanner.whitespace()
    guard scanner.position == scanner.bytes.count else { throw PasskeyVerificationError.rejected }
}

private struct UniqueJSONProperties {
    let bytes: [UInt8]
    var position = 0
    mutating func whitespace() {
        while position < bytes.count, [UInt8(0x20), 0x09, 0x0a, 0x0d].contains(bytes[position]) { position += 1 }
    }
    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard position < bytes.count, bytes[position] == byte else { throw PasskeyVerificationError.rejected }
        position += 1
    }
    mutating func string() throws -> String {
        whitespace()
        let start = position
        try consume(0x22)
        var escaped = false
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            if escaped { escaped = false; continue }
            if byte == 0x5c { escaped = true; continue }
            if byte == 0x22 {
                return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
            }
        }
        throw PasskeyVerificationError.rejected
    }
    mutating func value(depth: Int) throws {
        guard depth <= 16 else { throw PasskeyVerificationError.rejected }
        whitespace()
        guard position < bytes.count else { throw PasskeyVerificationError.rejected }
        switch bytes[position] {
        case 0x7b:
            try consume(0x7b)
            whitespace()
            if position < bytes.count, bytes[position] == 0x7d { position += 1; return }
            var keys = Set<String>()
            while true {
                let key = try string()
                guard keys.insert(key).inserted else { throw PasskeyVerificationError.rejected }
                try consume(0x3a)
                try value(depth: depth + 1)
                whitespace()
                guard position < bytes.count else { throw PasskeyVerificationError.rejected }
                if bytes[position] == 0x7d { position += 1; return }
                try consume(0x2c)
            }
        case 0x5b:
            try consume(0x5b)
            whitespace()
            if position < bytes.count, bytes[position] == 0x5d { position += 1; return }
            while true {
                try value(depth: depth + 1)
                whitespace()
                guard position < bytes.count else { throw PasskeyVerificationError.rejected }
                if bytes[position] == 0x5d { position += 1; return }
                try consume(0x2c)
            }
        case 0x22:
            _ = try string()
        default:
            let start = position
            while position < bytes.count, ![UInt8(0x20), 0x09, 0x0a, 0x0d, 0x2c, 0x7d, 0x5d].contains(bytes[position]) { position += 1 }
            guard position > start else { throw PasskeyVerificationError.rejected }
        }
    }
}

package enum AuthenticationTransportBody { case empty, finish, revocationOptions, facilityRename, productOffering }

package func validateAuthenticationTransportJSON(_ data: Data, shape: AuthenticationTransportBody) throws {
    try rejectDuplicateJSONProperties(data, maximumBytes: 131_072)
    let allowed: Set<String>
    switch shape {
    case .productOffering: allowed = ["kind", "capacity", "minimumDurationMinutes", "maximumDurationMinutes", "minimumNights", "maximumNights", "published"]
    case .facilityRename: allowed = ["name"]
    case .empty: allowed = []
    case .finish: allowed = ["challengeID", "credentialJSON"]
    case .revocationOptions: allowed = ["credentialID"]
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(object.keys).isSubset(of: allowed) else { throw PasskeyVerificationError.invalidInput }
}
