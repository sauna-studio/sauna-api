import Foundation
import Hummingbird
import SaunaAPIServer
import SaunaAPIDatabase
import SaunaAPIIdentity
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SaunaAPICommand {
    static func main() async {
        do {
            let configuration = try ServerConfiguration(
                port: ProcessInfo.processInfo.environment["PORT"],
                bindHost: ProcessInfo.processInfo.environment["BIND_HOST"]
            )
            let enabled = ProcessInfo.processInfo.environment["SAUNA_LOCAL_AUTH"]
            guard enabled == nil || enabled == "1" else { throw AuthenticationError.invalidInput }
            if enabled == "1" {
                guard configuration.bindHost == "127.0.0.1" || configuration.bindHost == "::1" else { throw AuthenticationError.invalidInput }
                let database = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
                let client = database.makeClient()
                let app = try makeApplication(configuration: configuration, api: .init(authenticationClient: client), services: [client])
                try await app.runService()
            } else {
                let app = try makeApplication(configuration: configuration)
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
