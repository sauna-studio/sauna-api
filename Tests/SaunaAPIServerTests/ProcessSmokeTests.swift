import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Testing

private enum SmokeError: Error {
    case missingExecutable
    case serverDidNotStart
    case shutdownTimedOut
}

private func executableURL() throws -> URL {
    // Swift Testing may run through a toolchain-hosted runner, so argv[0] need
    // not live in the package's build directory. The fixture bundle does,
    // including with --scratch-path and on Linux.
    var directory = Bundle.module.bundleURL
    for _ in 0..<5 {
        let candidate = directory.appendingPathComponent("SaunaAPI")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw SmokeError.missingExecutable
}

private func waitForExit(_ process: Process) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while process.isRunning {
        guard clock.now < deadline else { throw SmokeError.shutdownTimedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
    process.waitUntilExit()
}

@Suite(.serialized)
struct ProcessSmokeTests {
    @Test func executableServesHTTPAndExitsCleanlyOnSIGTERM() async throws {
        let process = Process()
        process.executableURL = try executableURL()
        let port = Int.random(in: 49152...65535)
        process.environment = ["PORT": String(port)]  // Exercise the executable's loopback default.
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                // Failure cleanup affects only this test's owned child process.
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 0.3
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let base = "http://127.0.0.1:\(port)"
        var started = false
        for _ in 0..<100 {
            guard process.isRunning else { throw SmokeError.serverDidNotStart }
            if let url = URL(string: base + "/health"),
               let (_, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                started = true
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard started else { throw SmokeError.serverDidNotStart }
        let url = try #require(URL(string: base + "/version"))
        let (body, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let version = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        let fixture = try #require(Bundle.module.url(forResource: "version", withExtension: "json", subdirectory: "Fixtures"))
        let expected = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: String])
        #expect(version == expected)

        process.terminate()  // SIGTERM, handled by Hummingbird's ServiceLifecycle.
        try await waitForExit(process)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)
    }

    @Test func invalidEnvironmentExitsWithoutEchoingItsValue() async throws {
        let process = Process()
        process.executableURL = try executableURL()
        let marker = "synthetic-private-port-marker"
        process.environment = ["PORT": marker]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        try await waitForExit(process)
        #expect(process.terminationStatus != 0)
        let message = output.fileHandleForReading.readDataToEndOfFile() + error.fileHandleForReading.readDataToEndOfFile()
        #expect(!String(decoding: message, as: UTF8.self).contains(marker))
    }
}
