import Foundation
import PostgresNIO
import SaunaAPIDatabase
import Testing
@testable import SaunaAPIIdentity

private func nonce(_ options: PasskeyOptions) throws -> Data {
  try authDecode(JSONDecoder().decode(TestOptions.self, from: options.optionsJSON).challenge)
}
private func manager(_ client: PostgresClient, party: LocalPasskeyRelyingParty = .customer) throws -> PasskeyManagementService {
  try .init(client: client, relyingParty: party)
}
private func authorize(_ service: PasskeyManagementService, fixture: RegisteredFixture, grant: SessionGrant) async throws -> PasskeyOptions {
  let options = try await service.beginAddition(token: grant.token, csrfToken: grant.session.csrfToken)
  let creation = try await service.authorizeAddition(challengeID: options.challengeID,
    credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 0, handle: nil),
    token: grant.token, csrfToken: grant.session.csrfToken)
  let object = try #require(JSONSerialization.jsonObject(with: creation.optionsJSON) as? [String: Any])
  let rp = try #require(object["rp"] as? [String: String])
  let selection = try #require(object["authenticatorSelection"] as? [String: Any])
  let exclusions = try #require(object["excludeCredentials"] as? [[String: Any]])
  let requiredPolicy = rp["id"] == "localhost" && selection["userVerification"] as? String == "required" && selection["residentKey"] as? String == "required" && object["attestation"] as? String == "none"
  #expect(requiredPolicy)
  let containsExisting = exclusions.contains { $0["id"] as? String == authEncode(fixture.key.id) && $0["type"] as? String == "public-key" }
  #expect(containsExisting)
  return creation
}
private func add(_ key: VirtualPasskey, service: PasskeyManagementService, fixture: RegisteredFixture, grant: SessionGrant) async throws {
  let options = try await authorize(service, fixture: fixture, grant: grant)
  let payload = try JSONDecoder().decode(TestOptions.self, from: options.optionsJSON)
  let sameHandle = try payload.user.map { try authDecode($0.id) == fixture.handle } ?? false
  #expect(sameHandle)
  try await service.finishAddition(challengeID: options.challengeID,
    credentialJSON: key.registration(challenge: nonce(options)), token: grant.token, csrfToken: grant.session.csrfToken)
}
private func insertFixtureKey(_ key: VirtualPasskey, fixture: RegisteredFixture, on connection: PostgresConnection) async throws {
  _ = try await authQuery("""
    INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up)
    VALUES (\(key.id),\(fixture.user),\(fixture.handle),\(key.cose),0,false,false)
    """, on: connection).collect()
}
private func backendPID(_ connection: PostgresConnection) async throws -> Int {
  let rows = try await authQuery("SELECT pg_backend_pid()", on: connection)
  for try await value in rows.decode(Int.self) { return value }
  throw AuthenticationError.unavailable
}
@discardableResult
private func waitForLock(_ client: PostgresClient, blockedBy: Int, queryPrefix: String) async throws -> Int {
  let deadline = ContinuousClock.now.advanced(by: .seconds(3))
  while ContinuousClock.now < deadline {
    let rows = try await client.query("SELECT pid FROM pg_stat_activity WHERE usename=current_user AND \(blockedBy)=ANY(pg_blocking_pids(pid)) AND query LIKE \(queryPrefix + "%")")
    for try await pid in rows.decode(Int.self) { return pid }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw AuthenticationError.unavailable
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
struct PasskeyManagementTests {
  @Test func additionalKeyBelongsToSameAccountAndRevocationRequiresAnotherKey() async throws {
    try await withAuthDatabase { client, records in
      let (first, _, _) = try await registration(client: client, records: records)
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let sessions = SessionStore(client: client, relyingParty: .customer)
      let initial = try await signedLogin(first, service: login, records: records, counter: 0)
      let initialList = try await service.list(token: initial.token)
      #expect(initialList.count == 1)
      let initialCurrent = initialList.allSatisfy { $0.isCurrentSessionCredential }
      #expect(initialCurrent)
      await rejected { _ = try await service.beginAddition(token: initial.token, csrfToken: AuthSessionToken().csrfToken) }
      let secondKey = VirtualPasskey()
      try await add(secondKey, service: service, fixture: first, grant: initial)
      await rejected { _ = try await sessions.resolve(token: initial.token) }
      let second = RegisteredFixture(key: secondKey, user: first.user, handle: first.handle)
      let grant = try await signedLogin(second, service: login, records: records, counter: 0)
      let list = try await service.list(token: grant.token)
      #expect(list.count == 2)
      let currentCount = list.filter { $0.isCurrentSessionCredential }.count
      #expect(currentCount == 1)
      let removal = try await service.beginRevocation(credentialID: authEncode(first.key.id), token: grant.token, csrfToken: grant.session.csrfToken)
      try await service.finishRevocation(challengeID: removal.challengeID,
        credentialJSON: second.key.assertion(challenge: nonce(removal), counter: 0, handle: nil),
        token: grant.token, csrfToken: grant.session.csrfToken)
      await rejected { _ = try await sessions.resolve(token: grant.token) }
      await rejected { _ = try await signedLogin(first, service: login, records: records, counter: 0) }
      let surviving = try await signedLogin(second, service: login, records: records, counter: 0)
      await rejected { _ = try await service.beginRevocation(credentialID: authEncode(second.key.id), token: surviving.token, csrfToken: surviving.session.csrfToken) }
      let final = try await service.list(token: surviving.token)
      #expect(final.count == 1)
    }
  }

  @Test func failedStepUpSpendsNonceAndCannotSkipAuthorization() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let options = try await service.beginAddition(token: grant.token, csrfToken: grant.session.csrfToken)
      let newKey = VirtualPasskey()
      await rejected { try await service.finishAddition(challengeID: options.challengeID,
        credentialJSON: newKey.registration(challenge: nonce(options)), token: grant.token, csrfToken: grant.session.csrfToken) }
      await rejected { _ = try await service.authorizeAddition(challengeID: options.challengeID,
        credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 1, handle: fixture.handle, tamperSignature: true), token: grant.token, csrfToken: grant.session.csrfToken) }
      await rejected { _ = try await service.authorizeAddition(challengeID: options.challengeID,
        credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 1, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken) }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 1)
      let rows = try await client.query("SELECT sign_count FROM public.passkey_credentials WHERE id=\(fixture.key.id)")
      for try await value in rows.decode(Int64.self) { #expect(value == 0) }
    }
  }

  @Test func wrongSessionUserOriginAndOperationCannotSpendBoundIntent() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let (other, _, _) = try await registration(client: client, records: records)
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let first = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let second = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let foreign = try await signedLogin(other, service: login, records: records, counter: 0)
      let options = try await service.beginAddition(token: first.token, csrfToken: first.session.csrfToken)
      let assertion = try fixture.key.assertion(challenge: nonce(options), counter: 0, handle: fixture.handle)
      for grant in [second, foreign] {
        await rejected { _ = try await service.authorizeAddition(challengeID: options.challengeID, credentialJSON: assertion, token: grant.token, csrfToken: grant.session.csrfToken) }
      }
      await rejected { _ = try await manager(client, party: .staff).authorizeAddition(challengeID: options.challengeID, credentialJSON: assertion, token: first.token, csrfToken: first.session.csrfToken) }
      await rejected { try await service.finishRevocation(challengeID: options.challengeID, credentialJSON: assertion, token: first.token, csrfToken: first.session.csrfToken) }
      let creation = try await service.authorizeAddition(challengeID: options.challengeID, credentialJSON: assertion, token: first.token, csrfToken: first.session.csrfToken)
      #expect(creation.challengeID == options.challengeID)
      let differentNonce = try nonce(creation) != nonce(options)
      #expect(differentNonce)
    }
  }

  @Test func rejectedRegistrationSpendsSecondPhaseWithoutAddingCredential() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let creation = try await authorize(service, fixture: fixture, grant: grant)
      let key = VirtualPasskey()
      await rejected { try await service.finishAddition(challengeID: creation.challengeID,
        credentialJSON: key.registration(challenge: nonce(creation), origin: "http://attacker.invalid"), token: grant.token, csrfToken: grant.session.csrfToken) }
      await rejected { try await service.finishAddition(challengeID: creation.challengeID,
        credentialJSON: key.registration(challenge: nonce(creation)), token: grant.token, csrfToken: grant.session.csrfToken) }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 1)
    }
  }

  @Test func finalCapacityCheckRejectsAnEarlierAuthorizedAddition() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      try await client.withConnection { connection in
        for _ in 0..<8 { try await insertFixtureKey(VirtualPasskey(), fixture: fixture, on: connection) }
      }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let creation = try await authorize(service, fixture: fixture, grant: grant)
      try await client.withConnection { try await insertFixtureKey(VirtualPasskey(), fixture: fixture, on: $0) }
      let newKey = VirtualPasskey()
      await rejected { try await service.finishAddition(challengeID: creation.challengeID,
        credentialJSON: newKey.registration(challenge: nonce(creation)), token: grant.token, csrfToken: grant.session.csrfToken) }
      await rejected { _ = try await service.beginAddition(token: grant.token, csrfToken: grant.session.csrfToken) }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 10)
    }
  }

  @Test func targetCannotAuthorizeItsOwnRevocationAndTheNonceRemainsSpent() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let extra = VirtualPasskey()
      try await client.withConnection { try await insertFixtureKey(extra, fixture: fixture, on: $0) }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let removal = try await service.beginRevocation(credentialID: authEncode(extra.id), token: grant.token, csrfToken: grant.session.csrfToken)
      await rejected { try await service.finishRevocation(challengeID: removal.challengeID,
        credentialJSON: extra.assertion(challenge: nonce(removal), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken) }
      await rejected { try await service.finishRevocation(challengeID: removal.challengeID,
        credentialJSON: fixture.key.assertion(challenge: nonce(removal), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken) }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 2)
    }
  }

  @Test func simultaneousMutualRevocationLeavesOneKeyAndNoOldSession() async throws {
    try await withAuthDatabase { client, records in
      let (first, _, _) = try await registration(client: client, records: records)
      let second = RegisteredFixture(key: VirtualPasskey(), user: first.user, handle: first.handle)
      try await client.withConnection { try await insertFixtureKey(second.key, fixture: first, on: $0) }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let a = try await signedLogin(first, service: login, records: records, counter: 0)
      let b = try await signedLogin(second, service: login, records: records, counter: 0)
      let removeB = try await service.beginRevocation(credentialID: authEncode(second.key.id), token: a.token, csrfToken: a.session.csrfToken)
      let removeA = try await service.beginRevocation(credentialID: authEncode(first.key.id), token: b.token, csrfToken: b.session.csrfToken)
      let outcomes = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
        for (options, fixture, grant) in [(removeB, first, a), (removeA, second, b)] {
          group.addTask {
            do {
              try await service.finishRevocation(challengeID: options.challengeID,
                credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken)
              return 1
            } catch AuthenticationError.rejected { return 0 }
            catch { return -1 }
          }
        }
        var result: [Int] = []
        for await outcome in group { result.append(outcome) }
        return result
      }
      #expect(outcomes.sorted() == [0, 1])
      for grant in [a, b] { await rejected { _ = try await SessionStore(client: client, relyingParty: .customer).resolve(token: grant.token) } }
      let rows = try await client.query("SELECT count(*) FROM public.passkey_credentials WHERE user_id=\(first.user) AND revoked_at IS NULL")
      for try await count in rows.decode(Int.self) { #expect(count == 1) }
    }
  }

  @Test func intentExpiryAfterTargetLockWaitRollsBackRevocation() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let extra = VirtualPasskey()
      try await client.withConnection { try await insertFixtureKey(extra, fixture: fixture, on: $0) }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let options = try await service.beginRevocation(credentialID: authEncode(extra.id), token: grant.token, csrfToken: grant.session.csrfToken)
      try await client.withConnection { blocker in
        let blockerPID = try await backendPID(blocker)
        _ = try await authQuery("BEGIN", on: blocker).collect()
        _ = try await authQuery("SELECT id FROM public.passkey_credentials WHERE id=\(extra.id) FOR UPDATE", on: blocker).collect()
        let attempt = Task {
          try await service.finishRevocation(challengeID: options.challengeID,
            credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken)
        }
        do {
          try await waitForLock(client, blockedBy: blockerPID, queryPrefix: "SELECT id FROM public.passkey_credentials")
          _ = try await authQuery("UPDATE public.passkey_management_intents SET expires_at=clock_timestamp()+interval '100 milliseconds' WHERE id=\(options.challengeID)", on: blocker).collect()
          try await Task.sleep(for: .milliseconds(160))
          _ = try await authQuery("COMMIT", on: blocker).collect()
          await rejected { try await attempt.value }
        } catch {
          _ = try? await authQuery("ROLLBACK", on: blocker).collect()
          attempt.cancel(); _ = try? await attempt.value
          throw error
        }
      }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 2)
    }
  }

  @Test func expiredSessionAfterItsRowLockIsDenied() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0, ttl: 1)
      try await client.withConnection { blocker in
        let blockerPID = try await backendPID(blocker)
        _ = try await authQuery("BEGIN", on: blocker).collect()
        _ = try await authQuery("SELECT token_hash FROM public.auth_sessions WHERE token_hash=\(grant.token.digest) FOR UPDATE", on: blocker).collect()
        let attempt = Task { try await service.list(token: grant.token) }
        do {
          try await waitForLock(client, blockedBy: blockerPID, queryPrefix: "WITH locked AS MATERIALIZED (%SELECT credential_id,created_at,expires_at,revoked_at")
          try await Task.sleep(for: .milliseconds(1_100))
          _ = try await authQuery("COMMIT", on: blocker).collect()
          await rejected { _ = try await attempt.value }
        } catch {
          _ = try? await authQuery("ROLLBACK", on: blocker).collect()
          attempt.cancel(); _ = try? await attempt.value
          throw error
        }
      }
    }
  }
  @Test func sessionAndAuthorizingCredentialAreRecheckedAfterStepUp() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let otherKey = RegisteredFixture(key: VirtualPasskey(), user: fixture.user, handle: fixture.handle)
      try await client.withConnection { try await insertFixtureKey(otherKey.key, fixture: fixture, on: $0) }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let sessions = SessionStore(client: client, relyingParty: .customer)
      let revokedGrant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let revokedOptions = try await authorize(service, fixture: fixture, grant: revokedGrant)
      try await sessions.revoke(token: revokedGrant.token, csrfToken: revokedGrant.session.csrfToken)
      await rejected { try await service.finishAddition(challengeID: revokedOptions.challengeID, credentialJSON: VirtualPasskey().registration(challenge: nonce(revokedOptions)), token: revokedGrant.token, csrfToken: revokedGrant.session.csrfToken) }
      let live = try await signedLogin(otherKey, service: login, records: records, counter: 0)
      let keyOptions = try await authorize(service, fixture: fixture, grant: live)
      _ = try await client.query("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE id=\(fixture.key.id)").collect()
      _ = try await sessions.resolve(token: live.token)
      await rejected { try await service.finishAddition(challengeID: keyOptions.challengeID, credentialJSON: VirtualPasskey().registration(challenge: nonce(keyOptions)), token: live.token, csrfToken: live.session.csrfToken) }
      let final = try await service.list(token: live.token)
      #expect(final.count == 1)
    }
  }

  @Test func cancelledRevocationDoesNotRestoreSpentIntentOrCommitChanges() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let extra = VirtualPasskey()
      try await client.withConnection { try await insertFixtureKey(extra, fixture: fixture, on: $0) }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let options = try await service.beginRevocation(credentialID: authEncode(extra.id), token: grant.token, csrfToken: grant.session.csrfToken)
      try await client.withConnection { blocker in
        let blockerPID = try await backendPID(blocker)
        _ = try await authQuery("BEGIN", on: blocker).collect()
        _ = try await authQuery("SELECT id FROM public.passkey_credentials WHERE id=\(extra.id) FOR UPDATE", on: blocker).collect()
        let attempt = Task {
          try await service.finishRevocation(challengeID: options.challengeID, credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken)
        }
        do {
          try await waitForLock(client, blockedBy: blockerPID, queryPrefix: "SELECT id FROM public.passkey_credentials")
          attempt.cancel()
          do { try await attempt.value; Issue.record("Expected owned management cancellation") }
          catch is CancellationError { }
          _ = try await authQuery("ROLLBACK", on: blocker).collect()
        } catch {
          _ = try? await authQuery("ROLLBACK", on: blocker).collect()
          attempt.cancel(); _ = try? await attempt.value
          throw error
        }
      }
      await rejected { try await service.finishRevocation(challengeID: options.challengeID, credentialJSON: fixture.key.assertion(challenge: nonce(options), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken) }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 2)
    }
  }

  @Test func uniqueInsertWaitRechecksExpiryAndRollsBackAdditionalKey() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let (foreign, _, _) = try await registration(client: client, records: records)
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let options = try await authorize(service, fixture: fixture, grant: grant)
      let candidate = VirtualPasskey()
      _ = try await client.query("UPDATE public.passkey_management_intents SET expires_at=clock_timestamp()+interval '1 second' WHERE id=\(options.challengeID)").collect()
      try await client.withConnection { blocker in
        let blockerPID = try await backendPID(blocker)
        _ = try await authQuery("BEGIN", on: blocker).collect()
        try await insertFixtureKey(candidate, fixture: foreign, on: blocker)
        let attempt = Task {
          try await service.finishAddition(challengeID: options.challengeID, credentialJSON: candidate.registration(challenge: nonce(options)), token: grant.token, csrfToken: grant.session.csrfToken)
        }
        do {
          try await waitForLock(client, blockedBy: blockerPID, queryPrefix: "INSERT INTO public.passkey_credentials")
          try await Task.sleep(for: .milliseconds(1_100))
          _ = try await authQuery("ROLLBACK", on: blocker).collect()
          await rejected { try await attempt.value }
        } catch {
          _ = try? await authQuery("ROLLBACK", on: blocker).collect()
          attempt.cancel(); _ = try? await attempt.value
          throw error
        }
      }
      let list = try await service.list(token: grant.token)
      #expect(list.count == 1)
      let rows = try await client.query("SELECT count(*) FROM public.passkey_credentials WHERE id=\(candidate.id)")
      for try await count in rows.decode(Int.self) { #expect(count == 0) }
    }
  }

  @Test func loginLinearizesBeforeManagementRevokesEveryEarlierSession() async throws {
    try await withAuthDatabase { client, records in
      let (fixture, _, _) = try await registration(client: client, records: records)
      let extra = VirtualPasskey()
      try await client.withConnection { try await insertFixtureKey(extra, fixture: fixture, on: $0) }
      let login = try PasskeyAuthService(client: client, relyingParty: .customer)
      let service = try manager(client)
      let grant = try await signedLogin(fixture, service: login, records: records, counter: 0)
      let management = try await service.beginRevocation(credentialID: authEncode(extra.id), token: grant.token, csrfToken: grant.session.csrfToken)
      let (loginOptions, binding, loginNonce) = try await loginOptions(login, records: records)
      try await client.withConnection { blocker in
        let blockerPID = try await backendPID(blocker)
        _ = try await authQuery("BEGIN", on: blocker).collect()
        _ = try await authQuery("SELECT id FROM public.passkey_credentials WHERE id=\(fixture.key.id) FOR UPDATE", on: blocker).collect()
        let loginAttempt = Task {
          try await login.finishAuthentication(challengeID: loginOptions.challengeID, binding: binding, credentialJSON: fixture.key.assertion(challenge: loginNonce, counter: 0, handle: fixture.handle))
        }
        var managementAttempt: Task<Void, any Error>?
        do {
          let loginPID = try await waitForLock(client, blockedBy: blockerPID, queryPrefix: "SELECT%passkey_credentials%")
          let attempt = Task {
            try await service.finishRevocation(challengeID: management.challengeID, credentialJSON: fixture.key.assertion(challenge: nonce(management), counter: 0, handle: fixture.handle), token: grant.token, csrfToken: grant.session.csrfToken)
          }
          managementAttempt = attempt
          try await waitForLock(client, blockedBy: loginPID, queryPrefix: "SELECT user_handle FROM public.passkey_accounts")
          _ = try await authQuery("COMMIT", on: blocker).collect()
          let earlier = try await loginAttempt.value
          try await attempt.value
          await rejected { _ = try await SessionStore(client: client, relyingParty: .customer).resolve(token: earlier.token) }
        } catch {
          _ = try? await authQuery("ROLLBACK", on: blocker).collect()
          loginAttempt.cancel(); managementAttempt?.cancel()
          _ = try? await loginAttempt.value; _ = try? await managementAttempt?.value
          throw error
        }
      }
    }
  }

}
