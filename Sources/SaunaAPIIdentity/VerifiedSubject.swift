public import Foundation

/// An identity established by the authentication module, never a client-supplied
/// user ID. There is intentionally no public initializer or decoding conformance.
/// Only verified Passkey/session paths inside this module construct it.
public struct VerifiedSubject: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let userID: UUID

    init(userID: UUID) {
        self.userID = userID
    }

    public var description: String { "VerifiedSubject(<redacted>)" }
    public var debugDescription: String { description }
}
