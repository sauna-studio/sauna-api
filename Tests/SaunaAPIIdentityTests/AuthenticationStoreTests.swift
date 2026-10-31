import Foundation
import PostgresNIO
import Testing
import SaunaAPIDatabase
@testable import SaunaAPIIdentity

private actor AuthFixtureRecords {
    var challenges: [UUID] = []
    var users: [UUID] = []
    func challenge(_ id: UUID) { challenges.append(id) }
    func user(_ id: UUID) { users.append(id) }
}
private struct TestOptions: Decodable {
    struct User: Decodable { let id: String }
    let challenge: String
    let user: User?
}
private func withAuthDatabase(_ body: @escaping @Sendable (PostgresClient, AuthFixtureRecords) async throws -> Void) async throws {
    var env = ProcessInfo.processInfo.environment
    env["PGDATABASE"] = "sauna_atlas_replay"
    let configuration = try LocalDatabaseConfiguration(environment: env)
    try await LocalDatabase.withClient(configuration: configuration, timeout: .seconds(25)) { client in
        let records = AuthFixtureRecords()
        func cleanup() async throws {
            for user in await records.users {
                _ = try await client.query("DELETE FROM public.auth_sessions WHERE user_id=\(user)").collect()
                _ = try await client.query("DELETE FROM public.passkey_credentials WHERE user_id=\(user)").collect()
                _ = try await client.query("DELETE FROM public.passkey_accounts WHERE user_id=\(user)").collect()
                _ = try await client.query("DELETE FROM public.users WHERE id=\(user)").collect()
            }
            for id in await records.challenges {
                _ = try await client.query("DELETE FROM public.passkey_registration_intents WHERE challenge_id=\(id)").collect()
                _ = try await client.query("DELETE FROM public.webauthn_challenges WHERE id=\(id)").collect()
            }
        }
        do { try await body(client, records); try await cleanup() }
        catch { try await cleanup(); throw error }
    }
}
private struct RegisteredFixture: Sendable {
    let key: VirtualPasskey
    let user: UUID
    let handle: Data
}
private func registration(client: PostgresClient, records: AuthFixtureRecords, key: VirtualPasskey = .init(), finish: Bool = true) async throws -> (RegisteredFixture, PasskeyOptions, PasskeyFlowBinding) {
    let service = try PasskeyAuthService(client: client, relyingParty: .customer)
    let binding = PasskeyFlowBinding.generate()
    let options = try await service.beginRegistration(binding: binding)
    await records.challenge(options.challengeID)
    let payload = try JSONDecoder().decode(TestOptions.self, from: options.optionsJSON)
    guard let handle = payload.user?.id else { throw AuthenticationError.unavailable }
    let rows = try await client.query("SELECT user_id FROM public.passkey_registration_intents WHERE challenge_id=\(options.challengeID)")
    var user: UUID?
    for try await id in rows.decode(UUID.self) { user = id }
    guard let user else { throw AuthenticationError.unavailable }
    await records.user(user)
    if finish {
        try await service.finishRegistration(challengeID: options.challengeID, binding: binding,
            credentialJSON: key.registration(challenge: authDecode(payload.challenge)))
    }
    return (.init(key: key, user: user, handle: try authDecode(handle)), options, binding)
}
private func loginOptions(_ service: PasskeyAuthService, records: AuthFixtureRecords) async throws -> (PasskeyOptions, PasskeyFlowBinding, Data) {
    let binding = PasskeyFlowBinding.generate()
    let options = try await service.beginAuthentication(binding: binding)
    await records.challenge(options.challengeID)
    let payload = try JSONDecoder().decode(TestOptions.self, from: options.optionsJSON)
    return (options, binding, try authDecode(payload.challenge))
}
private func signedLogin(_ fixture: RegisteredFixture, service: PasskeyAuthService, records: AuthFixtureRecords, counter: UInt32, ttl: Int = 28_800) async throws -> SessionGrant {
    let (options, binding, nonce) = try await loginOptions(service, records: records)
    return try await service.finishAuthentication(challengeID: options.challengeID, binding: binding,
        credentialJSON: fixture.key.assertion(challenge: nonce, counter: counter, handle: fixture.handle), sessionTTLSeconds: ttl)
}
private func rejected(_ body: () async throws -> Void) async {
    do { try await body(); Issue.record("Expected authentication rejection") }
    catch { let fixed = error as? AuthenticationError == .rejected; #expect(fixed) }
}

struct AuthenticationStoreTests {
    @Test func sessionTokensAreRedactedCanonicalAndCSRFIsBound() throws {
        let token = AuthSessionToken()
        let copy = try AuthSessionToken(encoded: token.encoded)
        let roundTrip = token.encoded == copy.encoded
        #expect(roundTrip)
        #expect(String(reflecting: token) == "AuthSessionToken(<redacted>)")
        try token.verifyCSRF(copy.csrfToken)
        #expect(throws: AuthenticationError.rejected) { try token.verifyCSRF(AuthSessionToken().csrfToken) }
        #expect(throws: AuthenticationError.invalidInput) { try AuthSessionToken(encoded: "invalid") }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func registrationRequiresSignedLoginAndSessionsRevoke() async throws {
        try await withAuthDatabase { client, records in
            let (fixture, _, _) = try await registration(client: client, records: records)
            let counts = try await client.query("SELECT count(*) FROM public.auth_sessions WHERE user_id=\(fixture.user)")
            for try await count in counts.decode(Int.self) { #expect(count == 0) }
            let service = try PasskeyAuthService(client: client, relyingParty: .customer)
            let sessions = SessionStore(client: client, relyingParty: .customer)
            let grant = try await signedLogin(fixture, service: service, records: records, counter: 1)
            let session = try await sessions.resolve(token: grant.token)
            let ownerMatches = session.subject.userID == fixture.user
            #expect(ownerMatches)
            #expect(String(describing: grant) == "SessionGrant(<redacted>)")
            await rejected { try await sessions.revoke(token: grant.token, csrfToken: AuthSessionToken().csrfToken) }
            _ = try await sessions.resolve(token: grant.token)
            await rejected { _ = try await SessionStore(client: client, relyingParty: .staff).resolve(token: grant.token) }
            try await sessions.revoke(token: grant.token, csrfToken: session.csrfToken)
            await rejected { _ = try await sessions.resolve(token: grant.token) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func rejectedSignatureSpendsChallengeWithoutCounterOrSession() async throws {
        try await withAuthDatabase { client, records in
            let (fixture, _, _) = try await registration(client: client, records: records)
            let service = try PasskeyAuthService(client: client, relyingParty: .customer)
            let (options, binding, nonce) = try await loginOptions(service, records: records)
            await rejected { _ = try await service.finishAuthentication(challengeID: options.challengeID, binding: binding,
                credentialJSON: fixture.key.assertion(challenge: nonce, counter: 1, handle: fixture.handle, tamperSignature: true)) }
            await rejected { _ = try await service.finishAuthentication(challengeID: options.challengeID, binding: binding,
                credentialJSON: fixture.key.assertion(challenge: nonce, counter: 1, handle: fixture.handle)) }
            let rows = try await client.query("SELECT sign_count,(SELECT count(*) FROM public.auth_sessions WHERE user_id=\(fixture.user)) FROM public.passkey_credentials WHERE id=\(fixture.key.id)")
            for try await (counter, count) in rows.decode((Int64, Int).self) { #expect(counter == 0); #expect(count == 0) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func duplicateCredentialCannotAttachToAnotherAccount() async throws {
        try await withAuthDatabase { client, records in
            let (original, _, _) = try await registration(client: client, records: records)
            let (other, options, binding) = try await registration(client: client, records: records, key: original.key, finish: false)
            let payload = try JSONDecoder().decode(TestOptions.self, from: options.optionsJSON)
            let service = try PasskeyAuthService(client: client, relyingParty: .customer)
            await rejected { try await service.finishRegistration(challengeID: options.challengeID, binding: binding, credentialJSON: original.key.registration(challenge: authDecode(payload.challenge))) }
            let rows = try await client.query("SELECT count(*) FROM public.users WHERE id=\(other.user)")
            for try await count in rows.decode(Int.self) { #expect(count == 0) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func simultaneousNonzeroCounterHasOneSessionWinner() async throws {
        try await withAuthDatabase { client, records in
            let (fixture, _, _) = try await registration(client: client, records: records)
            let service = try PasskeyAuthService(client: client, relyingParty: .customer)
            let first = try await loginOptions(service, records: records)
            let second = try await loginOptions(service, records: records)
            let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
                for (options, binding, nonce) in [first, second] {
                    group.addTask {
                        do { _ = try await service.finishAuthentication(challengeID: options.challengeID, binding: binding,
                            credentialJSON: fixture.key.assertion(challenge: nonce, counter: 1, handle: fixture.handle)); return 1 }
                        catch AuthenticationError.rejected { return 0 }
                        catch { return -1 }
                    }
                }
                var results: [Int] = []
                for await result in group { results.append(result) }
                return results
            }
            #expect(results.filter { $0 == 1 }.count == 1)
            #expect(results.filter { $0 == 0 }.count == 1)
            #expect(!results.contains(-1))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func expiryCredentialRevocationAndLogoutAllTakeEffect() async throws {
        try await withAuthDatabase { client, records in
            let (fixture, _, _) = try await registration(client: client, records: records)
            let service = try PasskeyAuthService(client: client, relyingParty: .customer)
            let sessions = SessionStore(client: client, relyingParty: .customer)
            let first = try await signedLogin(fixture, service: service, records: records, counter: 1)
            let second = try await signedLogin(fixture, service: service, records: records, counter: 2)
            try await sessions.revokeAll(token: first.token, csrfToken: first.session.csrfToken)
            await rejected { _ = try await sessions.resolve(token: first.token) }
            await rejected { _ = try await sessions.resolve(token: second.token) }
            let short = try await signedLogin(fixture, service: service, records: records, counter: 3, ttl: 1)
            try await Task.sleep(for: .milliseconds(1_100))
            await rejected { _ = try await sessions.resolve(token: short.token) }
            let active = try await signedLogin(fixture, service: service, records: records, counter: 4)
            _ = try await client.query("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE id=\(fixture.key.id)").collect()
            await rejected { _ = try await sessions.resolve(token: active.token) }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func operationDeadlineCancelsOnlyQueryAndPoolRecovers() async throws {
        try await withAuthDatabase { client, _ in
            let started = ContinuousClock.now
            do {
                _ = try await authenticationDeadline(timeout: .milliseconds(100)) {
                    try await authenticationConnection(client) { connection in
                        try await authQuery("SELECT pg_sleep(2)", on: connection).collect()
                    }
                }
                Issue.record("Expected operation deadline")
            } catch { let fixed = error as? AuthenticationError == .unavailable; #expect(fixed) }
            #expect(started.duration(to: .now) < .seconds(1))
            let rows = try await client.query("SELECT 1")
            for try await value in rows.decode(Int.self) { #expect(value == 1) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func cancelledTransactionRollsBackAndPoolRecovers() async throws {
        try await withAuthDatabase { client, records in
            let user = UUID()
            await records.user(user)
            let started = ContinuousClock.now
            do {
                _ = try await authenticationDeadline(timeout: .milliseconds(100)) {
                    try await authenticationTransaction(client) { transaction in
                            _ = try await authQuery("INSERT INTO public.users(id) VALUES (\(user))", on: transaction).collect()
                            _ = try await authQuery("SELECT pg_sleep(2)", on: transaction).collect()
                    }
                }
                Issue.record("Expected transaction deadline")
            } catch { let fixed = error as? AuthenticationError == .unavailable; #expect(fixed) }
            #expect(started.duration(to: .now) < .seconds(1))
            let rows = try await client.query("SELECT count(*) FROM public.users WHERE id=\(user)")
            for try await count in rows.decode(Int.self) { #expect(count == 0) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func thrownCancellationDiscardsTransactionWithoutTaskCancellation() async throws {
        try await withAuthDatabase { client, records in
            let user = UUID()
            await records.user(user)
            do {
                try await authenticationTransaction(client) { transaction in
                    _ = try await authQuery("INSERT INTO public.users(id) VALUES (\(user))", on: transaction).collect()
                    throw CancellationError()
                }
                Issue.record("Expected cancellation-shaped error")
            } catch is CancellationError { }
            #expect(!Task.isCancelled)
            let rows = try await client.query("SELECT count(*) FROM public.users WHERE id=\(user)")
            for try await count in rows.decode(Int.self) { #expect(count == 0) }
        }
    }

}
