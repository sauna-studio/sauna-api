import Foundation
import Testing
@testable import SaunaAPIDatabase

struct DatabaseTests {
    @Test func missingCredentialPathIsRejected() {
        #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: [:]) }
    }

    private func withFixture<Value>(_ body: ([String: String], URL) throws -> Value) throws -> Value {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic-fixture")
        FileManager.default.createFile(atPath: file.path, contents: Data("noncredential-test-fixture".utf8), attributes: [.posixPermissions: 0o600])
        let env = ["PGPASSWORD_FILE": file.path]
        _ = try LocalDatabaseConfiguration(environment: env)
        return try body(env, file)
    }

    @Test(arguments: ["example.com", "0.0.0.0", "localhost", "127.0.0.1.example.com"])
    func remoteOrAmbiguousHostIsRejected(host: String) throws {
        try withFixture { env, _ in
            var invalid = env
            invalid["PGHOST"] = host
            #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: invalid) }
        }
    }

    @Test(arguments: ["postgres", "production", "sauna_atlas_dev", "sauna_local;DROP DATABASE other"])
    func unexpectedDatabaseIsRejected(database: String) throws {
        try withFixture { env, _ in
            var invalid = env
            invalid["PGDATABASE"] = database
            #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: invalid) }
        }
    }

    @Test func adminRoleIsRejected() throws {
        try withFixture { env, _ in
            var invalid = env
            invalid["PGUSER"] = "sauna_admin"
            #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: invalid) }
        }
    }

    @Test(arguments: ["0", "65536", "-1", "+1", " 5432", "１２３", "5432\n"])
    func invalidPortIsRejected(port: String) throws {
        try withFixture { env, _ in
            var invalid = env
            invalid["PGPORT"] = port
            #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: invalid) }
        }
    }

    @Test func publicAndSymlinkedFileAreRejected() throws {
        try withFixture { env, file in
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: env) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let link = file.deletingLastPathComponent().appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            #expect(throws: LocalDatabaseError.invalidConfiguration) { try LocalDatabaseConfiguration(environment: ["PGPASSWORD_FILE": link.path]) }
        }
    }

    @Test func invalidTimeoutIsRejectedBeforeConnecting() async throws {
        let config = try withFixture { env, _ in try LocalDatabaseConfiguration(environment: env) }
        for timeout: Duration in [.zero, .seconds(-1), .seconds(31)] {
            do {
                let _: Int = try await LocalDatabase.withClient(configuration: config, timeout: timeout) { _ in 1 }
                Issue.record("Expected invalid timeout rejection")
            } catch {
                #expect(error as? LocalDatabaseError == .invalidConfiguration)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicitly configured local PostgreSQL password file"))
    func actualLocalPostgres18PoolAndCancellation() async throws {
        let config = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
        #expect(String(describing: config) == "LocalDatabaseConfiguration(<redacted>)")
        #expect(String(reflecting: config) == "LocalDatabaseConfiguration(<redacted>)")
        try await LocalDatabase.verify(configuration: config)
        let started = ContinuousClock.now
        do {
            let _: Int = try await LocalDatabase.withClient(configuration: config, timeout: .milliseconds(100)) { client in
                let rows = try await client.query("SELECT pg_sleep(2)")
                for try await _ in rows { }
                return 1
            }
            Issue.record("Expected bounded query timeout")
        } catch {
            #expect(error as? LocalDatabaseError == .unavailable)
        }
        #expect(started.duration(to: .now) < .seconds(1))
        // A subsequent fresh pool must still connect after the previous cancelled pool.
        try await LocalDatabase.verify(configuration: config)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicitly configured local PostgreSQL password file"))
    func disconnectedOwnBackendIsRedactedAndFreshPoolRecovers() async throws {
        let config = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
        do {
            let _: Int = try await LocalDatabase.withClient(configuration: config) { client in
                // Only this test's own backend; never select or terminate another session.
                let rows = try await client.query("SELECT pg_terminate_backend(pg_backend_pid())")
                for try await _ in rows { }
                return 1
            }
            Issue.record("Expected own backend disconnect")
        } catch {
            #expect(error as? LocalDatabaseError == .unavailable)
        }
        try await LocalDatabase.verify(configuration: config)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicitly configured local credential file"))
    func parentCancellationStaysCancellationAndPoolCloses() async throws {
        let config = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
        let task = Task {
            try await LocalDatabase.withClient(configuration: config) { client in
                let rows = try await client.query("SELECT pg_sleep(2)")
                for try await _ in rows { }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelled = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected parent cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cancelled.duration(to: .now) < .seconds(1))
        try await LocalDatabase.verify(configuration: config)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicitly configured local credential file"))
    func refusedConnectionIsBoundedAndRedacted() async throws {
        var env = ProcessInfo.processInfo.environment
        env["PGPORT"] = "1"
        let config = try LocalDatabaseConfiguration(environment: env)
        let started = ContinuousClock.now
        do {
            let _: Int = try await LocalDatabase.withClient(configuration: config, timeout: .milliseconds(200)) { client in
                let rows = try await client.query("SELECT 1")
                for try await value in rows.decode(Int.self) { return value }
                return 0
            }
            Issue.record("Expected connection failure")
        } catch {
            #expect(error as? LocalDatabaseError == .unavailable)
            #expect(String(describing: error) == "Local database is unavailable.")
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }
}
