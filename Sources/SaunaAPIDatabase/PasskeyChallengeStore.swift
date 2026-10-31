import Crypto
import Foundation
import Logging
import PostgresNIO

public enum PasskeyChallengeError: Error, Equatable, CustomStringConvertible {
    case invalidInput
    case notAvailable
    case unavailable
    public var description: String {
        switch self {
        case .invalidInput: "The passkey request is invalid."
        case .notAvailable: "The passkey request is not available."
        case .unavailable: "The passkey service is unavailable."
        }
    }
}

/// Local origins are explicit. Production RP/origin configuration is separate work.
public enum LocalPasskeyRelyingParty: Sendable {
    case customer, staff
    public var id: String { "localhost" }
    public var origin: String {
        switch self {
        case .customer: "http://localhost:5173"
        case .staff: "http://localhost:5174"
        }
    }
}

public enum PasskeyPurpose: String, Sendable {
    case registration, authentication
}

/// An independent browser-flow secret, not an authenticated session token.
/// Only its digest is persisted. A future HTTP adapter must use a private cookie.
public struct PasskeyFlowBinding: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let bytes: Data
    public static func generate() -> Self { Self(bytes: secureRandomBytes()) }
    private init(bytes: Data) { self.bytes = bytes }
    public init(encoded: String) throws {
        guard encoded.utf8.count == 43,
              encoded.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="),
              bytes.count == 32 else { throw PasskeyChallengeError.invalidInput }
        self.bytes = bytes
        guard self.encoded == encoded else { throw PasskeyChallengeError.invalidInput }
    }
    public var encoded: String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    fileprivate var digest: Data { Data(SHA256.hash(data: bytes)) }
    public var description: String { "PasskeyFlowBinding(<redacted>)" }
    public var debugDescription: String { description }
}

private func secureRandomBytes() -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

/// A nonce for later WebAuthn verification. Consuming it does not authenticate anyone.
public struct StoredPasskeyChallenge: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let challenge: Data
    public let expiresAt: Date
    public var description: String { "StoredPasskeyChallenge(<redacted>)" }
    public var debugDescription: String { description }
}

public struct PasskeyChallengeStore: Sendable {
    private enum Executor: Sendable {
        case client(PostgresClient)
        case connection(PostgresConnection)
    }
    private let executor: Executor
    private let relyingParty: LocalPasskeyRelyingParty
    public init(client: PostgresClient, relyingParty: LocalPasskeyRelyingParty) {
        self.executor = .client(client)
        self.relyingParty = relyingParty
    }
    // Transaction-pinned integration tests only; no escaped borrowed connection API.
    init(connection: PostgresConnection, relyingParty: LocalPasskeyRelyingParty) {
        self.executor = .connection(connection)
        self.relyingParty = relyingParty
    }

    public func issue(purpose: PasskeyPurpose, binding: PasskeyFlowBinding, ttlMilliseconds: Int = 300_000) async throws -> StoredPasskeyChallenge {
        guard (1...300_000).contains(ttlMilliseconds) else { throw PasskeyChallengeError.invalidInput }
        let id = UUID()
        let nonce = secureRandomBytes()
        do {
            let rows = try await query("""
                WITH instant AS MATERIALIZED (SELECT clock_timestamp() AS now)
                INSERT INTO public.webauthn_challenges(id,challenge,binding_hash,rp_id,origin,purpose,created_at,expires_at)
                SELECT \(id),\(nonce),\(binding.digest),\(relyingParty.id),\(relyingParty.origin),\(purpose.rawValue),instant.now,
                       instant.now + \(Double(ttlMilliseconds)) * interval '1 millisecond'
                FROM instant RETURNING id,challenge,expires_at
                """)
            for try await (id, challenge, expiresAt) in rows.decode((UUID, Data, Date).self) {
                return .init(id: id, challenge: challenge, expiresAt: expiresAt)
            }
            throw PasskeyChallengeError.unavailable
        } catch { throw mapped(error) }
    }

    /// Single-statement compare-and-consume. Call before cryptographic verification;
    /// a failed verification must not restore a spent challenge.
    public func consume(id: UUID, purpose: PasskeyPurpose, binding: PasskeyFlowBinding) async throws -> StoredPasskeyChallenge {
        do {
            let rows = try await query("""
                WITH locked AS MATERIALIZED (
                    SELECT id FROM public.webauthn_challenges
                    WHERE id=\(id) AND binding_hash=\(binding.digest)
                    FOR UPDATE
                ), instant AS MATERIALIZED (
                    SELECT locked.id, clock_timestamp() AS now FROM locked
                )
                UPDATE public.webauthn_challenges AS c SET consumed_at=instant.now
                FROM instant
                WHERE c.id=instant.id AND c.binding_hash=\(binding.digest)
                  AND c.rp_id=\(relyingParty.id) AND c.origin=\(relyingParty.origin)
                  AND c.purpose=\(purpose.rawValue) AND c.consumed_at IS NULL
                  AND c.created_at <= instant.now AND c.expires_at > instant.now
                RETURNING c.id,c.challenge,c.expires_at
                """)
            for try await (id, challenge, expiresAt) in rows.decode((UUID, Data, Date).self) {
                return .init(id: id, challenge: challenge, expiresAt: expiresAt)
            }
            throw PasskeyChallengeError.notAvailable
        } catch { throw mapped(error) }
    }

    private func query(_ sql: PostgresQuery) async throws -> PostgresRowSequence {
        switch executor {
        case .client(let client): try await client.query(sql)
        case .connection(let connection):
            try await connection.query(sql, logger: Logger(label: "SaunaPasskeyChallenges") { _ in SwiftLogNoOpLogHandler() })
        }
    }
    private func mapped(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? PasskeyChallengeError { return error }
        return PasskeyChallengeError.unavailable
    }
}
