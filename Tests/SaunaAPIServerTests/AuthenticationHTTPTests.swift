import Foundation
import HTTPTypes
import HummingbirdTesting
import OpenAPIRuntime
import SaunaAPIDatabase
import SaunaAPIIdentity
import Testing
@testable import SaunaAPIServer

@Suite(.serialized)
struct AuthenticationHTTPTests {
    @Test func originDuplicateCookiesAndBoundedBodiesFailClosed() async throws {
        let app = try makeApplication(configuration: .init())
        try await app.test(.live) { client in
            try await client.execute(uri: "/auth/session", method: .get) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers[.cacheControl] == "no-store")
            }
            try await client.execute(uri: "/auth/session", method: .get, headers: [.origin: "http://attacker.invalid"]) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(uri: "/auth/passkeys/registration/options", method: .post, headers: [.origin: "http://localhost:5173"]) { response in
                // No CSRF token exists before a login. The unavailable injected
                // service is reached, rather than a required-header 400.
                #expect(response.status == .serviceUnavailable)
            }
            try await client.execute(uri: "/auth/session", method: .get, headers: [.origin: "http://localhost:5173", .cookie: "__Host-sauna-customer-session=x; __Host-sauna-customer-session=y"]) { response in
                #expect(response.status == .badRequest)
            }
            let duplicate = "{\"challengeID\":\"one\",\"challengeID\":\"two\",\"credentialJSON\":\"synthetic-private-marker\"}"
            try await client.execute(uri: "/auth/passkeys/registration/finish", method: .post,
                headers: [.origin: "http://localhost:5173", .contentType: "application/json"], body: .init(string: duplicate)) { response in
                #expect(response.status == .badRequest)
                let hidden = !String(decoding: response.body.readableBytesView, as: UTF8.self).contains("synthetic-private-marker")
                #expect(hidden)
            }
            try await client.execute(uri: "/auth/passkeys/registration/finish", method: .post,
                headers: [.origin: "http://localhost:5173", .contentType: "application/json"], body: .init(repeating: 0x41, count: 131_073)) { response in
                #expect(response.status == .contentTooLarge)
                #expect(response.body.readableBytes < 200)
            }
        }
    }

    @Test func missingAndMistypedFinishFieldsReturnClosedProblems() async throws {
        let app = try makeApplication(configuration: .init())
        // These inputs pass JSON syntax/property validation but fail the generated
        // request decoder. Its diagnostics must not escape the auth boundary.
        let bodies = [
            "{}",
            "{\"challengeID\":\"00000000-0000-0000-0000-000000000001\"}",
            "{\"credentialJSON\":\"synthetic-private-marker\"}",
            "{\"challengeID\":123,\"credentialJSON\":\"synthetic-private-marker\"}",
            "{\"challengeID\":null,\"credentialJSON\":\"synthetic-private-marker\"}",
            "{\"challengeID\":\"00000000-0000-0000-0000-000000000001\",\"credentialJSON\":{\"synthetic-private-marker\":true}}",
            "{\"challengeID\":\"00000000-0000-0000-0000-000000000001\",\"credentialJSON\":null}",
        ]
        try await app.test(.live) { client in
            for path in ["registration", "authentication"] {
                for body in bodies {
                    try await client.execute(uri: "/auth/passkeys/\(path)/finish", method: .post,
                        headers: [.origin: "http://localhost:5173", .contentType: "application/json"], body: .init(string: body)) { response in
                        #expect(response.status == .badRequest)
                        #expect(response.headers[.contentType] == "application/problem+json")
                        #expect(response.headers[.cacheControl] == "no-store")
                        #expect(response.headers[.setCookie] == nil)
                        let closed = String(decoding: response.body.readableBytesView, as: UTF8.self)
                            == "{\"type\":\"about:blank\",\"title\":\"Bad Request\",\"status\":400}"
                        #expect(closed)
                    }
                }
            }
        }
    }

    @Test func localRateLimitReturnsFixedProblem() async throws {
        let middleware = AuthTransportMiddleware(limiter: .init(limit: 2))
        var request = HTTPRequest(method: .get, scheme: "http", authority: "localhost:8080", path: "/auth/session")
        request.headerFields[.origin] = "http://localhost:5173"
        for number in 0..<3 {
            let (response, _) = try await middleware.intercept(request, body: nil, metadata: .init(pathParameters: [:]), operationID: "getAuthSession") { _, _, _ in (.init(status: .ok), nil) }
            #expect(response.status == (number < 2 ? .ok : .tooManyRequests))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func flowCookieIsPrivateAndUnknownSessionsAreDeniedOverRealHTTP() async throws {
        var env = ProcessInfo.processInfo.environment
        env["PGDATABASE"] = "sauna_atlas_replay"
        let database = try LocalDatabaseConfiguration(environment: env)
        let pool = database.makeClient()
        let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: pool), services: [pool])
        try await app.test(.live) { client in
            try await client.execute(uri: "/auth/passkeys/registration/options", method: .post, headers: [.origin: "http://localhost:5173"]) { response in
                #expect(response.status == .ok)
                let raw = response.headers[.setCookie] ?? ""
                let attributes = raw.hasPrefix("__Host-sauna-customer-flow=") && raw.contains("; Secure;") && raw.contains("HttpOnly") && raw.contains("SameSite=Strict") && !raw.contains("Domain=")
                #expect(attributes)
                let privateCache = response.headers[.cacheControl] == "no-store"
                #expect(privateCache)
                let object = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as! [String: Any]
                let id = UUID(uuidString: object["challengeID"] as! String)!
                _ = try await pool.query("DELETE FROM public.passkey_registration_intents WHERE challenge_id=\(id)").collect()
                _ = try await pool.query("DELETE FROM public.webauthn_challenges WHERE id=\(id)").collect()
            }
            try await client.execute(uri: "/auth/session", method: .get,
                headers: [.origin: "http://localhost:5173", .cookie: "__Host-sauna-customer-session=" + String(repeating: "A", count: 43)]) { response in
                #expect(response.status == .unauthorized)
                #expect(response.headers[.setCookie] == nil)
                #expect(response.headers[.cacheControl] == "no-store")
            }
        }
    }
}
