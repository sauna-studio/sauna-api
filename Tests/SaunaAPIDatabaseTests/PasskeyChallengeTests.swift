import Foundation
import Logging
import PostgresNIO
import Testing
@testable import SaunaAPIDatabase
@testable import SaunaAPIIdentity

private let challengeLogger = Logger(label: "SaunaChallengeTests") { _ in SwiftLogNoOpLogHandler() }

private func challengeConfiguration() throws -> LocalDatabaseConfiguration {
    var environment = ProcessInfo.processInfo.environment
    environment["PGDATABASE"] = "sauna_atlas_replay"
    return try LocalDatabaseConfiguration(environment: environment)
}

private func withChallengeTransaction(_ body: @escaping @Sendable (PostgresConnection) async throws -> Void) async throws {
    try await LocalDatabase.withClient(configuration: challengeConfiguration(), timeout: .seconds(10)) { client in
        try await client.withConnection { connection in
            _ = try await connection.query("BEGIN", logger: challengeLogger).collect()
            do {
                try await body(connection)
                _ = try await connection.query("ROLLBACK", logger: challengeLogger).collect()
            } catch {
                _ = try await connection.query("ROLLBACK", logger: challengeLogger).collect()
                throw error
            }
        }
    }
}

private func challengeDenied(_ body: () async throws -> StoredPasskeyChallenge) async {
    do {
        _ = try await body()
        Issue.record("Expected fixed challenge rejection")
    } catch {
        #expect(error as? PasskeyChallengeError == .notAvailable)
        #expect(String(describing: error) == PasskeyChallengeError.notAvailable.description)
    }
}

struct PasskeyChallengeTests {
    @Test func bindingsAreCanonicalAndRedacted() throws {
        let binding = PasskeyFlowBinding.generate()
        let correctLength = binding.encoded.utf8.count == 43
        #expect(correctLength)
        let roundTrip = try PasskeyFlowBinding(encoded: binding.encoded)
        let equal = roundTrip.encoded == binding.encoded
        #expect(equal)
        #expect(String(describing: binding) == "PasskeyFlowBinding(<redacted>)")
        #expect(String(reflecting: binding) == "PasskeyFlowBinding(<redacted>)")
        for invalid in ["", String(repeating: "A", count: 42), String(repeating: "A", count: 44), String(repeating: "A", count: 42) + "+", String(repeating: "A", count: 42) + "B"] {
            #expect(throws: PasskeyChallengeError.invalidInput) { try PasskeyFlowBinding(encoded: invalid) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func issueConsumeReplayAndIndependentBindings() async throws {
        try await withChallengeTransaction { connection in
            let store = PasskeyChallengeStore(connection: connection, relyingParty: .customer)
            let binding = PasskeyFlowBinding.generate()
            let first = try await store.issue(purpose: .authentication, binding: binding)
            let second = try await store.issue(purpose: .authentication, binding: binding)
            #expect(first.id != second.id)
            let distinctNonces = first.challenge != second.challenge
            #expect(distinctNonces)
            #expect(first.challenge.count == 32)
            let storedHashes = try await connection.query("SELECT binding_hash FROM public.webauthn_challenges WHERE id=\(first.id)", logger: challengeLogger)
            for try await hash in storedHashes.decode(Data.self) {
                let raw = Data(base64Encoded: binding.encoded.replacing("-", with: "+").replacing("_", with: "/") + "=")!
                let hashOnly = hash.count == 32 && hash != raw
                #expect(hashOnly)
            }
            #expect(String(describing: first) == "StoredPasskeyChallenge(<redacted>)")
            await challengeDenied { try await store.consume(id: first.id, purpose: .authentication, binding: .generate()) }
            await challengeDenied { try await store.consume(id: first.id, purpose: .registration, binding: binding) }
            let staff = PasskeyChallengeStore(connection: connection, relyingParty: .staff)
            await challengeDenied { try await staff.consume(id: first.id, purpose: .authentication, binding: binding) }
            let consumed = try await store.consume(id: first.id, purpose: .authentication, binding: binding)
            let sameNonce = consumed.challenge == first.challenge
            #expect(sameNonce)
            await challengeDenied { try await store.consume(id: first.id, purpose: .authentication, binding: binding) }
            await challengeDenied { try await store.consume(id: UUID(), purpose: .authentication, binding: binding) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func wrongRPAndExpiryUseFreshDatabaseClock() async throws {
        try await withChallengeTransaction { connection in
            let store = PasskeyChallengeStore(connection: connection, relyingParty: .customer)
            let binding = PasskeyFlowBinding.generate()
            let wrongRP = try await store.issue(purpose: .registration, binding: binding)
            _ = try await connection.query("UPDATE public.webauthn_challenges SET rp_id='attacker.invalid' WHERE id=\(wrongRP.id)", logger: challengeLogger).collect()
            await challengeDenied { try await store.consume(id: wrongRP.id, purpose: .registration, binding: binding) }
            let expired = try await store.issue(purpose: .authentication, binding: binding, ttlMilliseconds: 50)
            _ = try await connection.query("SELECT pg_sleep(0.1)", logger: challengeLogger).collect()
            await challengeDenied { try await store.consume(id: expired.id, purpose: .authentication, binding: binding) }
            for invalid in [0, -1, 300_001, Int.max] {
                do {
                    _ = try await store.issue(purpose: .authentication, binding: binding, ttlMilliseconds: invalid)
                    Issue.record("Expected invalid TTL rejection")
                } catch { #expect(error as? PasskeyChallengeError == .invalidInput) }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func concurrentConsumptionHasExactlyOneWinner() async throws {
        // This test commits one temporary nonce in the owned disposable replay DB,
        // then deletes that exact UUID on both success and error paths.
        try await LocalDatabase.withClient(configuration: challengeConfiguration(), timeout: .seconds(10)) { client in
            let store = PasskeyChallengeStore(client: client, relyingParty: .customer)
            let binding = PasskeyFlowBinding.generate()
            let issued = try await store.issue(purpose: .authentication, binding: binding)
            do {
                let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
                    for _ in 0..<16 {
                        group.addTask {
                            do { _ = try await store.consume(id: issued.id, purpose: .authentication, binding: binding); return 1 }
                            catch PasskeyChallengeError.notAvailable { return 0 }
                            catch { return -1 }
                        }
                    }
                    var results: [Int] = []
                    for await result in group { results.append(result) }
                    return results
                }
                #expect(results.filter { $0 == 1 }.count == 1)
                #expect(results.filter { $0 == 0 }.count == 15)
                #expect(!results.contains(-1))
                _ = try await client.query("DELETE FROM public.webauthn_challenges WHERE id=\(issued.id)").collect()
            } catch {
                _ = try await client.query("DELETE FROM public.webauthn_challenges WHERE id=\(issued.id)").collect()
                throw error
            }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func deadlineIsCheckedAfterWaitingForRowLock() async throws {
        try await LocalDatabase.withClient(configuration: challengeConfiguration(), timeout: .seconds(10)) { client in
            let store = PasskeyChallengeStore(client: client, relyingParty: .customer)
            let binding = PasskeyFlowBinding.generate()
            let issued = try await store.issue(purpose: .authentication, binding: binding, ttlMilliseconds: 1_000)
            do {
                try await client.withConnection { locking in
                    _ = try await locking.query("BEGIN", logger: challengeLogger).collect()
                    var blockerPID = 0
                    for try await pid in try await locking.query("SELECT pg_backend_pid()", logger: challengeLogger).decode(Int.self) { blockerPID = pid }
                    _ = try await locking.query("SELECT id FROM public.webauthn_challenges WHERE id=\(issued.id) FOR UPDATE", logger: challengeLogger).collect()
                    let attempt = Task {
                        do { _ = try await store.consume(id: issued.id, purpose: .authentication, binding: binding); return 1 }
                        catch PasskeyChallengeError.notAvailable { return 0 }
                        catch { return -1 }
                    }
                    do {
                        var observedWait = false
                        for _ in 0..<50 {
                            let rows = try await client.query("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND \(blockerPID)=ANY(pg_blocking_pids(pid))")
                            for try await count in rows.decode(Int.self) { if count > 0 { observedWait = true } }
                            if observedWait { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        #expect(observedWait)
                        // A single timestamp sampled before the lock would allow
                        // this request. The dependent CTE must sample after unlock.
                        try await Task.sleep(for: .milliseconds(1_100))
                        _ = try await locking.query("COMMIT", logger: challengeLogger).collect()
                        let outcome = await attempt.value
                        #expect(outcome == 0)
                    } catch {
                        _ = try await locking.query("ROLLBACK", logger: challengeLogger).collect()
                        attempt.cancel()
                        _ = await attempt.value
                        throw error
                    }
                }
                _ = try await client.query("DELETE FROM public.webauthn_challenges WHERE id=\(issued.id)").collect()
            } catch {
                _ = try await client.query("DELETE FROM public.webauthn_challenges WHERE id=\(issued.id)").collect()
                throw error
            }
        }
    }

}
