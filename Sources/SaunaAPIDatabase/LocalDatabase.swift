import Foundation
import Logging
import PostgresNIO
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum LocalDatabaseError: Error, Equatable, CustomStringConvertible {
    case invalidConfiguration
    case unavailable
    public var description: String {
        switch self {
        case .invalidConfiguration: "Local database configuration is invalid."
        case .unavailable: "Local database is unavailable."
        }
    }
}

/// A local-only configuration. Cloud/remote TLS and tenant authorization are separate work.
public struct LocalDatabaseConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let host: String
    let port: Int
    let database: String
    private let password: String
    public var description: String { "LocalDatabaseConfiguration(<redacted>)" }
    public var debugDescription: String { description }

    public init(environment: [String: String]) throws {
        let host = environment["PGHOST"] ?? "127.0.0.1"
        let portValue = environment["PGPORT"] ?? "55432"
        let database = environment["PGDATABASE"] ?? "sauna_local"
        guard ["127.0.0.1", "::1"].contains(host),
              !portValue.isEmpty, portValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let port = Int(portValue), (1...65535).contains(port),
              (environment["PGUSER"] ?? "sauna_app") == "sauna_app",
              ["sauna_local", "sauna_atlas_replay"].contains(database),
              let path = environment["PGPASSWORD_FILE"], path.hasPrefix("/") else {
            throw LocalDatabaseError.invalidConfiguration
        }
        do {
            let url = URL(fileURLWithPath: path)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard values.isSymbolicLink != true,
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw LocalDatabaseError.invalidConfiguration
            }
            let value = try String(contentsOf: url, encoding: .utf8)
            let password = value.hasSuffix("\n") ? String(value.dropLast()) : value
            guard !password.isEmpty, !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
                throw LocalDatabaseError.invalidConfiguration
            }
            self.host = host
            self.port = port
            self.database = database
            self.password = password
        } catch {
            throw LocalDatabaseError.invalidConfiguration
        }
    }

    func client(timeout: Duration) -> PostgresClient {
        var configuration = PostgresClient.Configuration(host: host, port: port, username: "sauna_app", password: password, database: database, tls: .disable)
        configuration.options.connectTimeout = min(timeout, .seconds(2))
        configuration.options.maximumConnections = 4
        let logger = Logger(label: "SaunaDatabase") { _ in SwiftLogNoOpLogHandler() }
        return PostgresClient(configuration: configuration, backgroundLogger: logger)
    }
}

private enum DatabaseOutcome<Value: Sendable>: Sendable {
    case stopped
    case value(Value)
}

public enum LocalDatabase {
    /// A bounded operation with structured lifetime/cancellation of the actual PostgresNIO pool.
    public static func withClient<Result: Sendable>(
        configuration: LocalDatabaseConfiguration,
        timeout: Duration = .seconds(5),
        operation: @escaping @Sendable (PostgresClient) async throws -> Result
    ) async throws -> Result {
        guard timeout >= .milliseconds(1), timeout <= .seconds(30) else { throw LocalDatabaseError.invalidConfiguration }
        let client = configuration.client(timeout: timeout)
        do {
            return try await withThrowingTaskGroup(of: DatabaseOutcome<Result>.self) { tasks in
                tasks.addTask {
                    await client.run()
                    return .stopped
                }
                tasks.addTask { .value(try await operation(client)) }
                tasks.addTask {
                    try await Task.sleep(for: timeout)
                    throw LocalDatabaseError.unavailable
                }
                defer { tasks.cancelAll() }
                guard let outcome = try await tasks.next() else { throw LocalDatabaseError.unavailable }
                try Task.checkCancellation()
                switch outcome {
                case .value(let result): return result
                case .stopped: throw LocalDatabaseError.unavailable
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Preserve only our closed, fixed-message domain errors. Do not
            // generalize this to arbitrary caller/driver errors or descriptions.
            if let error = error as? FacilityStoreError { throw error }
            if let error = error as? PasskeyChallengeError { throw error }
            // Never stringify credentials, raw driver errors, queries, or parameter bindings.
            throw LocalDatabaseError.unavailable
        }
    }

    public static func verify(configuration: LocalDatabaseConfiguration) async throws {
        try await withClient(configuration: configuration) { client in
            let rows = try await client.query("SELECT current_setting('server_version_num')::int, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolcanlogin FROM pg_roles WHERE rolname=current_user")
            var count = 0
            for try await (version, superuser, createDB, createRole, replication, bypassRLS, canLogin) in rows.decode((Int, Bool, Bool, Bool, Bool, Bool, Bool).self) {
                guard version >= 180000, version < 190000, !superuser, !createDB, !createRole, !replication, !bypassRLS, canLogin else { throw LocalDatabaseError.unavailable }
                count += 1
            }
            guard count == 1 else { throw LocalDatabaseError.unavailable }
        }
    }
}
