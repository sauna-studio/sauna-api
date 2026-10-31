import Foundation
import Hummingbird
import SaunaAPIServer
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
            let app = try makeApplication(configuration: configuration)
            try await app.runService(gracefulShutdownSignals: [.sigterm, .sigint])
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
