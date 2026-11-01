public import Foundation
public import PostgresNIO
import WebAuthn

public struct ManagedPasskey: Sendable, CustomStringConvertible {
  public let credentialID: String
  public let createdAt: Date
  public let lastUsedAt: Date?
  public let isCurrentSessionCredential: Bool
  public var description: String { "ManagedPasskey(<redacted>)" }
}

struct ManagementSession: Sendable {
  let userID: UUID
  let handle: Data
  let credentialID: Data
}

func lockAuthenticationAccount(_ userID: UUID, on connection: PostgresConnection) async throws -> Data {
  let rows = try await authQuery("SELECT user_handle FROM public.passkey_accounts WHERE user_id=\(userID) FOR UPDATE", on: connection)
  for try await handle in rows.decode(Data.self) { return handle }
  throw AuthenticationError.rejected
}

func managementSession(token: AuthSessionToken, party: LocalPasskeyRelyingParty, on connection: PostgresConnection) async throws -> ManagementSession {
  let identities = try await authQuery("SELECT user_id FROM public.auth_sessions WHERE token_hash=\(token.digest) AND origin=\(party.origin)", on: connection)
  var userID: UUID?
  for try await value in identities.decode(UUID.self) { userID = value }
  guard let userID else { throw AuthenticationError.rejected }
  let handle = try await lockAuthenticationAccount(userID, on: connection)
  let rows = try await authQuery("""
    WITH locked AS MATERIALIZED (
      SELECT credential_id,created_at,expires_at,revoked_at FROM public.auth_sessions
      WHERE token_hash=\(token.digest) AND user_id=\(userID) AND origin=\(party.origin) FOR UPDATE
    )
    SELECT s.credential_id FROM locked AS s JOIN public.passkey_credentials AS c
      ON c.user_id=\(userID) AND c.id=s.credential_id
    WHERE s.revoked_at IS NULL AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp()
      AND c.revoked_at IS NULL
    """, on: connection)
  for try await id in rows.decode(Data.self) { return .init(userID: userID, handle: handle, credentialID: id) }
  throw AuthenticationError.rejected
}

func lockAccountSessions(_ userID: UUID, on connection: PostgresConnection) async throws {
  let rows = try await authQuery("SELECT token_hash FROM public.auth_sessions WHERE user_id=\(userID) ORDER BY token_hash FOR UPDATE", on: connection)
  for try await _ in rows.decode(Data.self) { }
}

private enum ManagementAction: String, Sendable { case add, revoke }
private struct ManagementIntent: Sendable {
  let userID: UUID
  let challenge: Data
  let target: Data?
  let authorizer: Data?
}

/// A session alone cannot enroll or remove an authenticator: a separately spent,
/// action-bound UV assertion precedes every change, including new-key creation.
public struct PasskeyManagementService: Sendable {
  private let client: PostgresClient
  private let party: LocalPasskeyRelyingParty
  private let verifier: LivePasskeyVerifier
  public init(client: PostgresClient, relyingParty: LocalPasskeyRelyingParty) throws {
    self.client = client; self.party = relyingParty
    self.verifier = try .init(origin: relyingParty.origin)
  }

  public func list(token: AuthSessionToken) async throws -> [ManagedPasskey] {
    try await authenticationDeadline {
      do {
        return try await authenticationTransaction(client) { connection in
          let session = try await managementSession(token: token, party: party, on: connection)
          let rows = try await authQuery("SELECT id,created_at,last_used_at FROM public.passkey_credentials WHERE user_id=\(session.userID) AND revoked_at IS NULL ORDER BY created_at,id", on: connection)
          var result: [ManagedPasskey] = []
          for try await (id, created, used) in rows.decode((Data, Date, Date?).self) {
            guard result.count < 10 else { throw AuthenticationError.unavailable }
            result.append(.init(credentialID: authEncode(id), createdAt: created, lastUsedAt: used, isCurrentSessionCredential: id == session.credentialID))
          }
          return result
        }
      } catch { throw authError(error) }
    }
  }

  public func beginAddition(token: AuthSessionToken, csrfToken: String) async throws -> PasskeyOptions {
    try await begin(action: .add, target: nil, token: token, csrfToken: csrfToken)
  }
  public func beginRevocation(credentialID: String, token: AuthSessionToken, csrfToken: String) async throws -> PasskeyOptions {
    let target = try authDecode(credentialID)
    return try await begin(action: .revoke, target: target, token: token, csrfToken: csrfToken)
  }

  private func begin(action: ManagementAction, target: Data?, token: AuthSessionToken, csrfToken: String) async throws -> PasskeyOptions {
    try token.verifyCSRF(csrfToken)
    return try await authenticationDeadline {
      do {
        return try await authenticationTransaction(client) { connection in
          let session = try await managementSession(token: token, party: party, on: connection)
          let ids = try await activeIDs(session.userID, on: connection)
          if action == .add { guard ids.count < 10 else { throw AuthenticationError.rejected } }
          else { guard let target, ids.count > 1, ids.contains(target) else { throw AuthenticationError.rejected } }
          let id = UUID(), nonce = authRandomBytes()
          _ = try await authQuery("""
            WITH instant AS MATERIALIZED (SELECT clock_timestamp() AS now)
            INSERT INTO public.passkey_management_intents(id,user_id,session_hash,rp_id,origin,action,target_credential_id,challenge,created_at,expires_at)
            SELECT \(id),\(session.userID),\(token.digest),\(party.id),\(party.origin),\(action.rawValue),\(target),\(nonce),instant.now,instant.now+interval '5 minutes' FROM instant
            """, on: connection).collect()
          let allowed = ids.filter { $0 != target }
          return .init(challengeID: id, optionsJSON: try requestOptions(nonce: nonce, ids: allowed))
        }
      } catch { throw authError(error) }
    }
  }

  public func authorizeAddition(challengeID: UUID, credentialJSON: Data, token: AuthSessionToken, csrfToken: String) async throws -> PasskeyOptions {
    try token.verifyCSRF(csrfToken)
    return try await authenticationDeadline {
      do {
        let intent = try await spend(id: challengeID, action: .add, registration: false, token: token)
        return try await authenticationTransaction(client) { connection in
          let session = try await managementSession(token: token, party: party, on: connection)
          guard session.userID == intent.userID else { throw AuthenticationError.rejected }
          let proof = try await assertion(credentialJSON, intent: intent, on: connection)
          try await validateSpentIntent(challengeID, token: token, on: connection)
          _ = try await managementSession(token: token, party: party, on: connection)
          let nonce = authRandomBytes()
          let rows = try await authQuery("""
            UPDATE public.passkey_management_intents SET authorization_credential_id=\(proof.credentialID),authorized_at=clock_timestamp(),registration_challenge=\(nonce)
            WHERE id=\(challengeID) AND user_id=\(session.userID) AND session_hash=\(token.digest) AND authorized_at IS NULL AND expires_at>clock_timestamp()
            RETURNING id
            """, on: connection)
          var updated = false
          for try await _ in rows.decode(UUID.self) { updated = true }
          guard updated else { throw AuthenticationError.rejected }
          let ids = try await activeIDs(session.userID, on: connection)
          guard ids.count < 10 else { throw AuthenticationError.rejected }
          return .init(challengeID: challengeID, optionsJSON: try creationOptions(nonce: nonce, handle: session.handle, ids: ids))
        }
      } catch { throw authError(error) }
    }
  }

  public func finishAddition(challengeID: UUID, credentialJSON: Data, token: AuthSessionToken, csrfToken: String) async throws {
    try token.verifyCSRF(csrfToken)
    try await authenticationDeadline {
      do {
        let intent = try await spend(id: challengeID, action: .add, registration: true, token: token)
        let proof = try await verifier.verifyRegistration(credentialJSON: credentialJSON, challenge: intent.challenge) { id in
          try await authenticationConnection(client) { connection in
            let rows = try await authQuery(AuthTypedQueries.credentialAvailability(id: id), on: connection)
            for try await count in rows.decode(Int.self) { return count == 0 }
            return false
          }
        }
        try await authenticationTransaction(client) { connection in
          let session = try await managementSession(token: token, party: party, on: connection)
          let ids = try await activeIDs(session.userID, on: connection)
          guard session.userID == intent.userID, let authorizer = intent.authorizer, ids.contains(authorizer), ids.count < 10 else { throw AuthenticationError.rejected }
          try await validateSpentIntent(challengeID, token: token, on: connection)
          _ = try await managementSession(token: token, party: party, on: connection)
          _ = try await authQuery("""
            INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up)
            VALUES (\(proof.credentialID),\(session.userID),\(session.handle),\(proof.publicKeyCOSE),\(Int64(proof.signCount)),\(proof.backupEligible),\(proof.isBackedUp))
            """, on: connection).collect()
          try await lockAccountSessions(session.userID, on: connection)
          try await validateSpentIntent(challengeID, token: token, on: connection)
          _ = try await managementSession(token: token, party: party, on: connection)
          _ = try await authQuery(AuthTypedQueries.revokeAllSessions(userID: session.userID), on: connection).collect()
        }
      } catch { throw authError(error) }
    }
  }

  public func finishRevocation(challengeID: UUID, credentialJSON: Data, token: AuthSessionToken, csrfToken: String) async throws {
    try token.verifyCSRF(csrfToken)
    try await authenticationDeadline {
      do {
        let intent = try await spend(id: challengeID, action: .revoke, registration: false, token: token)
        try await authenticationTransaction(client) { connection in
          let session = try await managementSession(token: token, party: party, on: connection)
          let ids = try await activeIDs(session.userID, on: connection)
          guard session.userID == intent.userID, let target = intent.target, ids.count > 1, ids.contains(target) else { throw AuthenticationError.rejected }
          let targets = try await authQuery("SELECT id FROM public.passkey_credentials WHERE user_id=\(session.userID) AND id=\(target) AND revoked_at IS NULL FOR UPDATE", on: connection)
          var targetActive = false
          for try await _ in targets.decode(Data.self) { targetActive = true }
          guard targetActive else { throw AuthenticationError.rejected }
          let proof = try await assertion(credentialJSON, intent: intent, on: connection)
          guard proof.credentialID != target, try await activeIDs(session.userID, on: connection).count > 1 else { throw AuthenticationError.rejected }
          try await lockAccountSessions(session.userID, on: connection)
          try await validateSpentIntent(challengeID, token: token, on: connection)
          _ = try await managementSession(token: token, party: party, on: connection)
          _ = try await authQuery("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE user_id=\(session.userID) AND id=\(target) AND revoked_at IS NULL", on: connection).collect()
          _ = try await authQuery("UPDATE public.passkey_management_intents SET authorization_credential_id=\(proof.credentialID),authorized_at=clock_timestamp() WHERE id=\(challengeID)", on: connection).collect()
          _ = try await authQuery(AuthTypedQueries.revokeAllSessions(userID: session.userID), on: connection).collect()
        }
      } catch { throw authError(error) }
    }
  }

  // Commit the spend in its own transaction before crypto; later rollback must not
  // turn a signed or rejected management ceremony into a reusable grant.
  private func spend(id: UUID, action: ManagementAction, registration: Bool, token: AuthSessionToken) async throws -> ManagementIntent {
    try await authenticationTransaction(client) { connection in
      let session = try await managementSession(token: token, party: party, on: connection)
      let rows: PostgresRowSequence
      if registration {
        rows = try await authQuery("""
          WITH locked AS MATERIALIZED (SELECT id FROM public.passkey_management_intents WHERE id=\(id) AND user_id=\(session.userID) AND session_hash=\(token.digest) AND action=\(action.rawValue) AND rp_id=\(party.id) AND origin=\(party.origin) FOR UPDATE),
          instant AS MATERIALIZED (SELECT locked.id,clock_timestamp() AS now FROM locked)
          UPDATE public.passkey_management_intents AS i SET registration_consumed_at=instant.now FROM instant
          WHERE i.id=instant.id AND i.authorized_at IS NOT NULL AND i.registration_challenge IS NOT NULL AND i.registration_consumed_at IS NULL AND i.created_at<=instant.now AND i.expires_at>instant.now
            AND EXISTS(SELECT 1 FROM public.passkey_credentials AS c WHERE c.user_id=i.user_id AND c.id=i.authorization_credential_id AND c.revoked_at IS NULL)
          RETURNING i.user_id,i.registration_challenge,i.target_credential_id,i.authorization_credential_id
          """, on: connection)
      } else {
        rows = try await authQuery("""
          WITH locked AS MATERIALIZED (SELECT id FROM public.passkey_management_intents WHERE id=\(id) AND user_id=\(session.userID) AND session_hash=\(token.digest) AND action=\(action.rawValue) AND rp_id=\(party.id) AND origin=\(party.origin) FOR UPDATE),
          instant AS MATERIALIZED (SELECT locked.id,clock_timestamp() AS now FROM locked)
          UPDATE public.passkey_management_intents AS i SET consumed_at=instant.now FROM instant
          WHERE i.id=instant.id AND i.consumed_at IS NULL AND i.created_at<=instant.now AND i.expires_at>instant.now
          RETURNING i.user_id,i.challenge,i.target_credential_id,i.authorization_credential_id
          """, on: connection)
      }
      for try await (userID, nonce, target, authorizer) in rows.decode((UUID, Data, Data?, Data?).self) { return .init(userID: userID, challenge: nonce, target: target, authorizer: authorizer) }
      throw AuthenticationError.rejected
    }
  }

  private func assertion(_ data: Data, intent: ManagementIntent, on connection: PostgresConnection) async throws -> VerifiedPasskeyAssertion {
    guard data.count <= 65_536 else { throw AuthenticationError.invalidInput }
    let id: Data
    do { id = try authDecode(JSONDecoder().decode(ManagementCredentialReference.self, from: data).id) }
    catch { throw AuthenticationError.invalidInput }
    let rows = try await authQuery("""
      SELECT user_handle,public_key_cose,sign_count,backup_eligible FROM public.passkey_credentials
      WHERE user_id=\(intent.userID) AND id=\(id) AND revoked_at IS NULL FOR UPDATE
      """, on: connection)
    for try await (handle, key, count, backup) in rows.decode((Data, Data, Int64, Bool).self) {
      guard let counter = UInt32(exactly: count) else { throw AuthenticationError.rejected }
      let proof = try verifier.verifyAssertion(credentialJSON: data, challenge: intent.challenge, storedCredential: .init(credentialID: id, userHandle: handle, publicKeyCOSE: key, signCount: counter, backupEligible: backup))
      _ = try await authQuery("UPDATE public.passkey_credentials SET sign_count=\(Int64(proof.newSignCount)),is_backed_up=\(proof.isBackedUp),last_used_at=clock_timestamp() WHERE id=\(id) AND user_id=\(intent.userID)", on: connection).collect()
      return proof
    }
    throw AuthenticationError.rejected
  }
  private func activeIDs(_ userID: UUID, on connection: PostgresConnection) async throws -> [Data] {
    let rows = try await authQuery("SELECT id FROM public.passkey_credentials WHERE user_id=\(userID) AND revoked_at IS NULL ORDER BY id", on: connection)
    var ids: [Data] = []
    for try await id in rows.decode(Data.self) { ids.append(id) }
    return ids
  }
  private func validateSpentIntent(_ id: UUID, token: AuthSessionToken, on connection: PostgresConnection) async throws {
    let rows = try await authQuery("""
      WITH locked AS MATERIALIZED (SELECT id,expires_at FROM public.passkey_management_intents WHERE id=\(id) AND session_hash=\(token.digest) AND rp_id=\(party.id) AND origin=\(party.origin) FOR UPDATE)
      SELECT id FROM locked WHERE expires_at>clock_timestamp()
      """, on: connection)
    for try await _ in rows.decode(UUID.self) { return }
    throw AuthenticationError.rejected
  }
  private func requestOptions(nonce: Data, ids: [Data]) throws -> Data {
    var options = try verifier.authenticationOptions(challenge: nonce)
    options.allowCredentials = ids.map { .init(id: Array($0)) }
    return try JSONEncoder().encode(options)
  }
  private func creationOptions(nonce: Data, handle: Data, ids: [Data]) throws -> Data {
    // The pinned upstream model omits excludeCredentials. Keep the library's
    // encoding intact until its typed model supports this field (Issue #49).
    try JSONEncoder().encode(CreationOptionsWithExclusions(
      base: verifier.registrationOptions(challenge: nonce, userHandle: handle),
      excludeCredentials: ids.map { .init(id: Array($0)) }))
  }
}
private struct ManagementCredentialReference: Decodable { let id: String }

private struct CreationOptionsWithExclusions: Encodable {
  let base: PublicKeyCredentialCreationOptions
  let excludeCredentials: [PublicKeyCredentialDescriptor]
  enum CodingKeys: String, CodingKey { case excludeCredentials }
  func encode(to encoder: any Encoder) throws {
    try base.encode(to: encoder)
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(excludeCredentials, forKey: .excludeCredentials)
  }
}
