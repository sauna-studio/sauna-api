public import Foundation

/// An identity established by the authentication module, never a client-supplied
/// user ID. There is intentionally no public initializer or decoding conformance.
/// A production producer requires the later Passkey/session implementation.
public struct VerifiedSubject: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID: UUID

    init(userID: UUID) {
        self.userID = userID
    }

    public var description: String { "VerifiedSubject(<redacted>)" }
    public var debugDescription: String { description }
}
