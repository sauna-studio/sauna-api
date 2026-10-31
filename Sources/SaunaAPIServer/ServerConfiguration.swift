public struct ServerConfiguration: Sendable, Equatable {
    public enum ConfigurationError: Error, CustomStringConvertible {
        case invalidPort
        case invalidBindHost

        public var description: String {
            switch self {
            case .invalidPort: "PORT must contain only ASCII digits and be between 1 and 65535."
            case .invalidBindHost: "BIND_HOST must be 127.0.0.1, ::1, or 0.0.0.0."
            }
        }
    }

    public let port: Int
    public let bindHost: String

    public init(port: String? = nil, bindHost: String? = nil) throws {
        if let port {
            guard !port.isEmpty,
                  port.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(port), (1...65535).contains(parsed)
            else { throw ConfigurationError.invalidPort }
            self.port = parsed
        } else {
            self.port = 8080
        }
        let host = bindHost ?? "127.0.0.1"
        guard ["127.0.0.1", "::1", "0.0.0.0"].contains(host) else {
            throw ConfigurationError.invalidBindHost
        }
        self.bindHost = host
    }
}
