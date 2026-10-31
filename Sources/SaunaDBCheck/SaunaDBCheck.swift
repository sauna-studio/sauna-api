import Foundation
import SaunaAPIDatabase
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct SaunaDBCheck {
    static func main() async {
        do {
            let config = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
            try await LocalDatabase.verify(configuration: config)
            print("Local PostgreSQL 18 connection pool check passed.")
        } catch {
            FileHandle.standardError.write(Data("Local database check failed; credentials and driver details are not displayed.\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
