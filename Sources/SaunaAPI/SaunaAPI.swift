import Foundation
import Hummingbird
import SaunaAPIServer
import SaunaAPIDatabase
import SaunaAPIIdentity
import ServiceLifecycle
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SaunaAPICommand {
    static func main() async {
        do {
            let environment = ProcessInfo.processInfo.environment
            let configuration = try ServerConfiguration(port: environment["PORT"], bindHost: environment["BIND_HOST"])
            let tracing = try bootstrapLocalHTTPTracing(collectorHost: environment["SAUNA_LOCAL_OTLP_HOST"])
            let services = tracing.map { [$0] } ?? []
            let enabled = environment["SAUNA_LOCAL_AUTH"]
            guard enabled == nil || enabled == "1" else { throw AuthenticationError.invalidInput }
            let employmentMode = environment["SAUNA_LOCAL_EMPLOYMENT_RECHECK"]
            if let employmentMode {
                guard employmentMode == "synthetic-ineligible", enabled == "1",
                      environment["PGDATABASE"] == "sauna_atlas_replay"
                else { throw AuthenticationError.invalidInput }
            }
            if enabled == "1" {
                guard configuration.bindHost == "127.0.0.1" || configuration.bindHost == "::1" else { throw AuthenticationError.invalidInput }
                let database = try LocalDatabaseConfiguration(environment: environment)
                let client = database.makeClient()
                var localServices: [any Service] = [client]
                if employmentMode != nil {
                    // Limit synthetic outcomes before leasing; choosing an outcome
                    // after a global claim could delay checks for other enrollments.
                    localServices.append(WorkspaceEmploymentScheduler(
                        store: WorkspaceEmploymentStore(client: client),
                        scope: .synthetic,
                        verify: { _ in .ineligible }
                    ))
                }
                let app = try makeApplication(
                    configuration: configuration, api: .init(authenticationClient: client),
                    services: services + localServices, traceHTTP: tracing != nil
                )
                try await app.runService()
            } else {
                let app = try makeApplication(configuration: configuration, services: services, traceHTTP: tracing != nil)
                try await app.runService()
            }
        } catch let error as ServerConfiguration.ConfigurationError {
            FileHandle.standardError.write(Data((error.description + "\n").utf8))
            exit(EXIT_FAILURE)
        } catch {
            // Do not stringify arbitrary framework errors or dump environment values.
            FileHandle.standardError.write(Data("Sauna API failed to start or stopped unexpectedly.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
