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

private enum SmokeError: Error, Equatable {
    case missingExecutable
    case readinessTimedOut
    case childReadinessFailed(probe: ProbeMetadata, listener: Bool?, threadCount: Int?, expectedExecutable: Bool?)
    case childExitedBeforeReadiness(status: Int32)
    case shutdownTimedOut
}

private enum ProbeMetadata: Equatable {
    case notAttempted
    case httpStatus(Int)
    case cannotConnectToHost
    case timedOut
    case connectionLost
    case otherTransport
    case invalidResponse
}

private func safeProbeMetadata(_ error: Error) -> ProbeMetadata {
    guard let error = error as? URLError else { return .otherTransport }
    switch error.code {
    case .cannotConnectToHost: return .cannotConnectToHost
    case .timedOut: return .timedOut
    case .networkConnectionLost: return .connectionLost
    default: return .otherTransport
    }
}

private func listenerMetadata(port: Int) -> Bool? {
    #if os(Linux)
    guard let table = try? String(contentsOfFile: "/proc/net/tcp", encoding: .utf8) else { return nil }
    let target = String(port, radix: 16).uppercased()
    return table.split(separator: "\n").dropFirst().contains { line in
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return fields.count > 3 && String(fields[1].split(separator: ":").last ?? "") == target && fields[3] == "0A"
    }
    #else
    return nil
    #endif
}

private func threadMetadata(process: Process) -> Int? {
    #if os(Linux)
    guard let status = try? String(contentsOfFile: "/proc/\(process.processIdentifier)/status", encoding: .utf8),
          let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Threads:") }),
          let value = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last
    else { return nil }
    return Int(value)
    #else
    return nil
    #endif
}

private func executableMetadata(process: Process) -> Bool? {
    #if os(Linux)
    guard let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(process.processIdentifier)/exe"),
          let expected = process.executableURL else { return nil }
    return URL(fileURLWithPath: actual).resolvingSymlinksInPath() == expected.resolvingSymlinksInPath()
    #else
    return nil
    #endif
}

private enum SmokeChildState {
    case running
    case exited(status: Int32)
}

private func waitForReadiness(
    timeout: Duration = .seconds(15),
    childState: () -> SmokeChildState,
    probe: () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    // Retry counts couple cold-start tolerance to probe speed instead of elapsed time.
    while true {
        try Task.checkCancellation()
        if case .exited(let status) = childState() {
            throw SmokeError.childExitedBeforeReadiness(status: status)
        }
        guard clock.now < deadline else { throw SmokeError.readinessTimedOut }
        let ready = try await probe()
        try Task.checkCancellation()
        guard clock.now < deadline else { throw SmokeError.readinessTimedOut }
        if ready { return }
        try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(30))))
    }
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
        // Unread pipes can block the child; raw startup output is not safe diagnostic metadata.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
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
        sessionConfiguration.timeoutIntervalForResource = 0.3
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let base = "http://127.0.0.1:\(port)"
        var lastProbe = ProbeMetadata.notAttempted
        do {
            try await waitForReadiness(
                childState: {
                    if process.isRunning { return .running }
                    process.waitUntilExit()
                    return .exited(status: process.terminationStatus)
                },
                probe: {
                    guard let url = URL(string: base + "/health") else { return false }
                    do {
                        let (_, response) = try await session.data(from: url)
                        guard let status = (response as? HTTPURLResponse)?.statusCode, (100...599).contains(status) else {
                            lastProbe = .invalidResponse
                            return false
                        }
                        lastProbe = .httpStatus(status)
                        return status == 200
                    } catch {
                        try Task.checkCancellation()
                        lastProbe = safeProbeMetadata(error)
                        return false
                    }
                }
            )
        } catch SmokeError.readinessTimedOut {
            // Framework error descriptions and child output can contain request/environment values.
            throw SmokeError.childReadinessFailed(
                probe: lastProbe, listener: listenerMetadata(port: port), threadCount: threadMetadata(process: process),
                expectedExecutable: executableMetadata(process: process)
            )
        }
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

    @Test func readinessDiagnosticsDiscardUntrustedErrorDetails() {
        let marker = "synthetic-private-transport-marker"
        let cases: [(URLError.Code, ProbeMetadata)] = [
            (.cannotConnectToHost, .cannotConnectToHost), (.timedOut, .timedOut),
            (.networkConnectionLost, .connectionLost), (.badURL, .otherTransport),
        ]
        for (code, expected) in cases {
            let error = URLError(code, userInfo: [NSLocalizedDescriptionKey: marker, NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/synthetic-private-transport-marker")!])
            let safe = safeProbeMetadata(error)
            #expect(safe == expected)
            #expect(!String(describing: safe).contains(marker))
        }
        #expect(safeProbeMetadata(NSError(domain: marker, code: 123, userInfo: [NSLocalizedDescriptionKey: marker])) == .otherTransport)
    }

    @Test func readinessCanArriveAfterColdStartupDelay() async throws {
        let clock = ContinuousClock()
        let readyAt = clock.now.advanced(by: .milliseconds(3300))
        try await waitForReadiness(childState: { .running }, probe: { clock.now >= readyAt })
        #expect(clock.now >= readyAt)
    }

    @Test func unavailableChildReachesBoundedReadinessFailure() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        await #expect(throws: SmokeError.readinessTimedOut) {
            try await waitForReadiness(timeout: .milliseconds(100), childState: { .running }, probe: { false })
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(2))
    }

    @Test func earlyExitPreservesOnlyExitStatusMetadata() async throws {
        await #expect(throws: SmokeError.childExitedBeforeReadiness(status: 23)) {
            try await waitForReadiness(childState: { .exited(status: 23) }, probe: { false })
        }
    }

    @Test func cancelledReadinessIsNotReportedAsStartupFailure() async throws {
        await #expect(throws: CancellationError.self) {
            try await waitForReadiness(childState: { .running }, probe: { throw CancellationError() })
        }
    }

}
