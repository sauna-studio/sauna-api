public import Foundation
public import PostgresNIO

public struct PasskeyOptions: Sendable {
  public let challengeID: UUID
  public let optionsJSON: Data
}

/// Anonymous registration creates a new account only; it cannot select an existing
/// user or issue a session. A signed, UV assertion is required for every login.
public struct PasskeyAuthService: Sendable {
  private let client: PostgresClient
  private let relyingParty: LocalPasskeyRelyingParty
  private let verifier: any PasskeyVerifying
  public init(client: PostgresClient, relyingParty: LocalPasskeyRelyingParty) throws {
    self.client = client
    self.relyingParty = relyingParty
    self.verifier = try LivePasskeyVerifier(origin: relyingParty.origin)
  }
  // Tests may inject doubles; production HTTP cannot choose a verifier.
  init(
    client: PostgresClient, relyingParty: LocalPasskeyRelyingParty, verifier: any PasskeyVerifying
  ) {
    self.client = client
    self.relyingParty = relyingParty
    self.verifier = verifier
  }

  public func beginRegistration(binding: PasskeyFlowBinding) async throws -> PasskeyOptions {
    try await authenticationDeadline { try await beginRegistrationOperation(binding: binding) }
  }
  public func finishRegistration(
    challengeID: UUID, binding: PasskeyFlowBinding, credentialJSON: Data
  ) async throws {
    try await authenticationDeadline {
      try await finishRegistrationOperation(
        challengeID: challengeID, binding: binding, credentialJSON: credentialJSON)
    }
  }
  public func beginAuthentication(binding: PasskeyFlowBinding) async throws -> PasskeyOptions {
    try await authenticationDeadline { try await beginAuthenticationOperation(binding: binding) }
  }
  public func finishAuthentication(
    challengeID: UUID, binding: PasskeyFlowBinding, credentialJSON: Data,
    sessionTTLSeconds: Int = 28_800
  ) async throws -> SessionGrant {
    try await authenticationDeadline {
      try await finishAuthenticationOperation(
        challengeID: challengeID, binding: binding, credentialJSON: credentialJSON,
        sessionTTLSeconds: sessionTTLSeconds)
    }
  }

  private func beginRegistrationOperation(binding: PasskeyFlowBinding) async throws
    -> PasskeyOptions
  {
    do {
      return try await authenticationTransaction(client) { connection in
        let challenge = try await PasskeyChallengeStore(
          connection: connection, relyingParty: relyingParty
        ).issue(purpose: .registration, binding: binding)
        let userID = UUID()
        let handle = authRandomBytes()
        _ = try await authQuery(
          "INSERT INTO public.passkey_registration_intents(challenge_id,user_id,user_handle) VALUES (\(challenge.id),\(userID),\(handle))",
          on: connection
        ).collect()
        let options = try verifier.registrationOptions(
          challenge: challenge.challenge, userHandle: handle)
        return .init(challengeID: challenge.id, optionsJSON: try JSONEncoder().encode(options))
      }
    } catch { throw authError(error) }
  }
  private func finishRegistrationOperation(
    challengeID: UUID, binding: PasskeyFlowBinding, credentialJSON: Data
  ) async throws {
    do {
      // Autocommit this spend BEFORE verification/persistence: any later
      // failure must not roll it back into an unspent challenge.
      let challenge = try await PasskeyChallengeStore(client: client, relyingParty: relyingParty)
        .consume(id: challengeID, purpose: .registration, binding: binding)
      let proof = try await verifier.verifyRegistration(
        credentialJSON: credentialJSON, challenge: challenge.challenge
      ) { id in
        try await authenticationConnection(client) { connection in
          let rows = try await authQuery(
            AuthTypedQueries.credentialAvailability(id: id), on: connection)
          for try await count in rows.decode(Int.self) { return count == 0 }
          return false
        }
      }
      try await authenticationTransaction(client) { connection in
        let intents = try await authQuery(
          "SELECT user_id,user_handle FROM public.passkey_registration_intents WHERE challenge_id=\(challengeID) FOR UPDATE",
          on: connection)
        var intent: (UUID, Data)?
        for try await value in intents.decode((UUID, Data).self) { intent = value }
        guard let (userID, handle) = intent else { throw AuthenticationError.rejected }
        _ = try await authQuery("INSERT INTO public.users(id) VALUES (\(userID))", on: connection)
          .collect()
        _ = try await authQuery(
          "INSERT INTO public.passkey_accounts(user_id,user_handle) VALUES (\(userID),\(handle))",
          on: connection
        ).collect()
        _ = try await authQuery(
          """
          INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up)
          VALUES (\(proof.credentialID),\(userID),\(handle),\(proof.publicKeyCOSE),\(Int64(proof.signCount)),\(proof.backupEligible),\(proof.isBackedUp))
          """, on: connection
        ).collect()
        _ = try await authQuery(
          "DELETE FROM public.passkey_registration_intents WHERE challenge_id=\(challengeID)",
          on: connection
        ).collect()
      }
    } catch { throw authError(error) }
  }
  private func beginAuthenticationOperation(binding: PasskeyFlowBinding) async throws
    -> PasskeyOptions
  {
    do {
      let challenge = try await PasskeyChallengeStore(client: client, relyingParty: relyingParty)
        .issue(purpose: .authentication, binding: binding)
      return .init(
        challengeID: challenge.id,
        optionsJSON: try JSONEncoder().encode(
          verifier.authenticationOptions(challenge: challenge.challenge)))
    } catch { throw authError(error) }
  }
  private func finishAuthenticationOperation(
    challengeID: UUID, binding: PasskeyFlowBinding, credentialJSON: Data,
    sessionTTLSeconds: Int = 28_800
  ) async throws -> SessionGrant {
    do {
      guard (1...86_400).contains(sessionTTLSeconds), credentialJSON.count <= 65_536 else {
        throw AuthenticationError.invalidInput
      }
      let challenge = try await PasskeyChallengeStore(client: client, relyingParty: relyingParty)
        .consume(id: challengeID, purpose: .authentication, binding: binding)
      // This reference only locates server-stored material. The verifier
      // rechecks canonical id/rawId/userHandle against that stored record.
      let reference: CredentialReference
      do {
        reference = try JSONDecoder().decode(CredentialReference.self, from: credentialJSON)
      } catch { throw AuthenticationError.invalidInput }
      let credentialID = try authDecode(reference.id)
      return try await authenticationTransaction(client) { connection in
        let owners = try await authQuery("SELECT user_id FROM public.passkey_credentials WHERE id=\(credentialID)", on: connection)
        var lockedUserID: UUID?
        for try await owner in owners.decode(UUID.self) { lockedUserID = owner }
        guard let lockedUserID else { throw AuthenticationError.rejected }
        // Credential management and session issuance share one account lock;
        // otherwise a concurrent login could escape a management revoke-all.
        _ = try await lockAuthenticationAccount(lockedUserID, on: connection)
        let rows = try await authQuery(
          AuthTypedQueries.credentialForAuthentication(id: credentialID), on: connection)
        var record: (UUID, Data, Data, Int64, Bool)?
        for try await value in rows.decode((UUID, Data, Data, Int64, Bool).self) { record = value }
        guard let (userID, handle, key, counter, eligible) = record,
          userID == lockedUserID, let oldCounter = UInt32(exactly: counter)
        else { throw AuthenticationError.rejected }
        let proof = try verifier.verifyAssertion(
          credentialJSON: credentialJSON, challenge: challenge.challenge,
          storedCredential: .init(
            credentialID: credentialID, userHandle: handle, publicKeyCOSE: key,
            signCount: oldCounter, backupEligible: eligible))
        guard proof.credentialID == credentialID, proof.backupEligible == eligible else {
          throw AuthenticationError.rejected
        }
        _ = try await authQuery(
          "UPDATE public.passkey_credentials SET sign_count=\(Int64(proof.newSignCount)),is_backed_up=\(proof.isBackedUp),last_used_at=clock_timestamp() WHERE id=\(credentialID)",
          on: connection
        ).collect()
        return try await SessionStore.issue(
          on: connection, userID: userID, credentialID: credentialID, relyingParty: relyingParty,
          ttlSeconds: sessionTTLSeconds)
      }
    } catch { throw authError(error) }
  }
}
private struct CredentialReference: Decodable { let id: String }
