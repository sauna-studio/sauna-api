import Crypto
public import Foundation
import Logging
public import PostgresNIO

public enum AuthenticationError: Error, Equatable, CustomStringConvertible {
  case invalidInput, rejected, unavailable
  public var description: String {
    switch self {
    case .invalidInput: "The authentication request is invalid."
    case .rejected: "Authentication is required or the request was rejected."
    case .unavailable: "Authentication is temporarily unavailable."
    }
  }
}

func authRandomBytes() -> Data {
  var generator = SystemRandomNumberGenerator()
  return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
func authEncode(_ bytes: Data) -> String {
  bytes.base64EncodedString().replacing("+", with: "-").replacing(
    "/", with: "_"
  ).replacing("=", with: "")
}
func authDecode(_ value: String, maximum: Int = 1023) throws -> Data {
  guard !value.isEmpty, value.utf8.count <= (maximum * 4 + 2) / 3,
    value.utf8.allSatisfy({
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        || $0 == 95
    }),
    let data = Data(
      base64Encoded: value.replacing("-", with: "+").replacing("_", with: "/")
        + String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)),
    !data.isEmpty, data.count <= maximum, authEncode(data) == value
  else { throw AuthenticationError.invalidInput }
  return data
}

public struct AuthSessionToken: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let bytes: Data
  init() { bytes = authRandomBytes() }
  public init(encoded: String) throws {
    bytes = try authDecode(encoded, maximum: 32)
    guard bytes.count == 32 else { throw AuthenticationError.invalidInput }
  }
  public var encoded: String { authEncode(bytes) }
  var digest: Data { Data(SHA256.hash(data: bytes)) }
  public var csrfToken: String {
    authEncode(
      Data(
        HMAC<SHA256>.authenticationCode(
          for: Data("sauna.csrf.v1".utf8), using: SymmetricKey(data: bytes))))
  }
  func verifyCSRF(_ value: String) throws {
    guard let code = try? authDecode(value, maximum: 32), code.count == 32,
      HMAC<SHA256>.isValidAuthenticationCode(
        code, authenticating: Data("sauna.csrf.v1".utf8), using: SymmetricKey(data: bytes))
    else {
      throw AuthenticationError.rejected
    }
  }
  public var description: String { "AuthSessionToken(<redacted>)" }
  public var debugDescription: String { description }
}

public struct AuthenticatedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
  public let subject: VerifiedSubject
  public let expiresAt: Date
  public let csrfToken: String
  public var description: String { "AuthenticatedSession(<redacted>)" }
  public var debugDescription: String { description }
}
public struct SessionGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let token: AuthSessionToken
  public let session: AuthenticatedSession
  public var description: String { "SessionGrant(<redacted>)" }
  public var debugDescription: String { description }
}

let authLogger = Logger(label: "SaunaAuthentication") { _ in SwiftLogNoOpLogHandler() }
func authQuery(_ sql: PostgresQuery, on connection: PostgresConnection) async throws
  -> PostgresRowSequence
{
  try Task.checkCancellation()
  guard !connection.isClosed else { throw AuthenticationError.unavailable }
  return try await connection.query(sql, logger: authLogger)
}
func authError(_ error: any Error) -> any Error {
  if error is CancellationError || Task.isCancelled { return CancellationError() }
  if let error = error as? AuthenticationError { return error }
  if let error = error as? PasskeyVerificationError {
    switch error {
    case .invalidInput: return AuthenticationError.invalidInput
    case .rejected: return AuthenticationError.rejected
    case .unavailable: return AuthenticationError.unavailable
    }
  }
  if let error = error as? PasskeyChallengeError {
    switch error {
    case .invalidInput: return AuthenticationError.invalidInput
    case .notAvailable: return AuthenticationError.rejected
    case .unavailable: return AuthenticationError.unavailable
    }
  }
  if let transaction = error as? PostgresTransactionError,
    transaction.rollbackError == nil, transaction.commitError == nil, transaction.beginError == nil,
    let closure = transaction.closureError
  {
    return authError(closure)
  }
  if let sql = error as? PSQLError, sql.serverInfo?[.sqlState] == "23505" {
    return AuthenticationError.rejected
  }
  return AuthenticationError.unavailable
}

/// Session validation is the only production producer of VerifiedSubject.
public struct SessionStore: Sendable {
  private let client: PostgresClient
  private let relyingParty: LocalPasskeyRelyingParty
  public init(client: PostgresClient, relyingParty: LocalPasskeyRelyingParty) {
    self.client = client
    self.relyingParty = relyingParty
  }
  public func resolve(token: AuthSessionToken) async throws -> AuthenticatedSession {
    try await authenticationDeadline { try await resolveOperation(token: token) }
  }
  public func revoke(token: AuthSessionToken, csrfToken: String) async throws {
    try await authenticationDeadline {
      try await revokeOperation(token: token, csrfToken: csrfToken)
    }
  }
  public func revokeAll(token: AuthSessionToken, csrfToken: String) async throws {
    try await authenticationDeadline {
      try await revokeAllOperation(token: token, csrfToken: csrfToken)
    }
  }
  private func resolveOperation(token: AuthSessionToken) async throws -> AuthenticatedSession {
    do {
      return try await authenticationConnection(client) { connection in
        let rows = try await authQuery(
          AuthTypedQueries.sessionLookup(tokenHash: token.digest, origin: relyingParty.origin),
          on: connection)
        for try await (userID, expiresAt) in rows.decode((UUID, Date).self) {
          return .init(
            subject: VerifiedSubject(userID: userID), expiresAt: expiresAt,
            csrfToken: token.csrfToken)
        }
        throw AuthenticationError.rejected
      }
    } catch { throw authError(error) }
  }
  private func revokeOperation(token: AuthSessionToken, csrfToken: String) async throws {
    try token.verifyCSRF(csrfToken)
    do {
      _ = try await authenticationConnection(client) { connection in
        try await authQuery(
          AuthTypedQueries.revokeSession(tokenHash: token.digest, origin: relyingParty.origin),
          on: connection
        ).collect()
      }
    } catch { throw authError(error) }
  }
  private func revokeAllOperation(token: AuthSessionToken, csrfToken: String) async throws {
    try token.verifyCSRF(csrfToken)
    do {
      _ = try await authenticationTransaction(client) { connection in
        let session = try await managementSession(token: token, party: relyingParty, on: connection)
        try await lockAccountSessions(session.userID, on: connection)
        _ = try await managementSession(token: token, party: relyingParty, on: connection)
        return try await authQuery(
          AuthTypedQueries.revokeAllSessions(userID: session.userID), on: connection
        ).collect()
      }
    } catch { throw authError(error) }
  }
  // Only the cryptographic login transaction can issue a session; no public factory.
  static func issue(
    on connection: PostgresConnection, userID: UUID, credentialID: Data,
    relyingParty: LocalPasskeyRelyingParty, ttlSeconds: Int
  ) async throws -> SessionGrant {
    guard (1...86_400).contains(ttlSeconds) else { throw AuthenticationError.invalidInput }
    let token = AuthSessionToken()
    let rows = try await authQuery(
      """
      WITH instant AS MATERIALIZED (SELECT clock_timestamp() AS now)
      INSERT INTO public.auth_sessions(token_hash,user_id,credential_id,origin,created_at,expires_at)
      SELECT \(token.digest),\(userID),\(credentialID),\(relyingParty.origin),instant.now,instant.now+\(Double(ttlSeconds))*interval '1 second'
      FROM instant RETURNING expires_at
      """, on: connection)
    for try await expiresAt in rows.decode(Date.self) {
      return .init(
        token: token,
        session: .init(
          subject: VerifiedSubject(userID: userID), expiresAt: expiresAt, csrfToken: token.csrfToken
        ))
    }
    throw AuthenticationError.unavailable
  }
}
