import Foundation
import HummingbirdTesting
import SaunaAPIContract
import SaunaAPIServer
import Testing

@Suite(.serialized)
struct HTTPTests {
    @Test func healthAndVersionUseRealHTTPAndPublicContract() async throws {
        let app = try makeApplication(configuration: .init())
        try await app.test(.live) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
                #expect(response.headers[.server] == nil)
                let body = Data(response.body.readableBytesView)
                let health = try JSONDecoder().decode(Components.Schemas.Health.self, from: body)
                #expect(health.status == .ok)
            }
            try await client.execute(uri: "/version", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.hasPrefix("application/json") == true)
                #expect(response.headers[.server] == nil)
                let body = Data(response.body.readableBytesView)
                let version = try JSONDecoder().decode(Components.Schemas.Version.self, from: body)
                #expect(version.apiVersion == "1.0.0")
                #expect(version.version == "0.1.0")
                let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?![\s\S])"#
                #expect(version.apiVersion.range(of: pattern, options: .regularExpression) != nil)
                #expect(version.version.range(of: pattern, options: .regularExpression) != nil)
            }
        }
    }

    @Test func unavailableResponsesUseFixedProblemOverHTTP() async throws {
        let app = try makeApplication(configuration: .init(), api: .init(isAvailable: false))
        try await app.test(.live) { client in
            for path in ["/health", "/version"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .serviceUnavailable)
                    #expect(response.headers[.contentType]?.hasPrefix("application/problem+json") == true)
                    let problem = try JSONDecoder().decode(
                        Components.Schemas.ServiceUnavailableProblem.self,
                        from: Data(response.body.readableBytesView)
                    )
                    #expect(problem._type.rawValue == "about:blank")
                    #expect(problem.title.rawValue == "Service Unavailable")
                    #expect(problem.status.rawValue == 503)
                }
            }
        }
    }

    @Test func invalidRequestsNeverEchoRequestDataOrInternalDetails() async throws {
        let app = try makeApplication(configuration: .init())
        try await app.test(.live) { client in
            let marker = "synthetic-private-request-marker"
            try await client.execute(
                uri: "/health?probe=\(marker)", method: .get,
                headers: [.accept: "application/xml", .authorization: marker]
            ) { response in
                #expect(response.status == .notAcceptable)
                #expect(response.body.readableBytes == 0)
                #expect(response.headers[.server] == nil)
            }
            try await client.execute(uri: "/missing-\(marker)", method: .get) { response in
                #expect(response.status == .notFound)
                #expect(!String(decoding: response.body.readableBytesView, as: UTF8.self).contains(marker))
            }
        }
    }
}
