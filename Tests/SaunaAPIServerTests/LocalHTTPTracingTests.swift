@testable import SaunaAPIServer
import Testing

struct LocalHTTPTracingTests {
    @Test(arguments: ["127.0.0.1", "10.0.0.8", "172.16.1.2", "172.31.0.1", "192.168.64.4"])
    func acceptsLocalCollectorAddresses(host: String) throws {
        #expect(try localCollectorEndpoint(host: host) == "http://\(host):4318/v1/traces")
    }

    @Test(arguments: [
        "", "localhost", "8.8.8.8", "172.32.0.1", "192.169.1.1", "192.168.1.256",
        "127.0.0.01", "http://127.0.0.1", "127.0.0.1:4318", "127.0.0.1/path", "127.0.0.1@10.0.0.1",
    ])
    func rejectsNonlocalOrAmbiguousCollectorAddresses(host: String) {
        #expect(throws: LocalTracingError.invalidCollectorHost) { try localCollectorEndpoint(host: host) }
    }

    @Test func collectorIsOptIn() throws {
        #expect(try bootstrapLocalHTTPTracing(collectorHost: nil) == nil)
    }
}
