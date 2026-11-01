import Foundation
import HTTPTypes
import HummingbirdTesting
import PostgresNIO
import Testing
@testable import SaunaAPIServer

struct ProductNameHTTPTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL"))
    func legacyStaffNamesPreserveValidUnicodeAndRejectInvalidWireValues() async throws {
        try await withFacilityHTTPFixture { fixture in
            let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: fixture.pool))
            try await app.test(.live) { client in
                let headers = fixture.headers(fixture.manager)
                for value in [String(repeating: "a", count: 200), String(repeating: "サ", count: 200), String(repeating: "e\u{301}", count: 100)] {
                    _ = try await fixture.pool.query("UPDATE public.products SET name=\(value) WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product)").collect()
                    for path in [fixture.pathA, fixture.pathA + "/\(fixture.product)"] {
                        try await client.execute(uri: path, method: .get, headers: headers) { response in
                            #expect(response.status == .ok)
                            let body = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                            let product: [String: Any]
                            if path == fixture.pathA {
                                product = try #require((body["products"] as? [[String: Any]])?.first)
                            } else { product = body }
                            #expect(product["name"] as? String == value)
                        }
                    }
                }
                let invalid = String(repeating: "a", count: 200) + " "
                _ = try await fixture.pool.query("UPDATE public.products SET name=\(invalid) WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product)").collect()
                for path in [fixture.pathA, fixture.pathA + "/\(fixture.product)"] {
                    try await client.execute(uri: path, method: .get, headers: headers) { response in
                        #expect(response.status == .serviceUnavailable)
                        #expect(response.headers[.cacheControl] == "no-store")
                        #expect(response.headers[.setCookie] == nil)
                        let fixed = String(decoding: response.body.readableBytesView, as: UTF8.self) == "{\"type\":\"about:blank\",\"title\":\"Service Unavailable\",\"status\":503}"
                        #expect(fixed)
                    }
                }
                let renamed = String(repeating: "サ", count: 200)
                let oversized = try JSONSerialization.data(withJSONObject: ["name": " " + renamed + " "])
                try await client.execute(uri: fixture.pathA + "/\(fixture.product)", method: .patch, headers: headers,
                                         body: .init(bytes: oversized)) { response in
                    #expect(response.status == .badRequest)
                }
                let afterRejected = try await fixture.pool.query("SELECT name FROM public.products WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product)").collect()
                #expect(afterRejected.count == 1)
                for row in afterRejected { #expect(try row.decode(String.self) == invalid) }
                let json = try JSONSerialization.data(withJSONObject: ["name": renamed])
                try await client.execute(uri: fixture.pathA + "/\(fixture.product)", method: .patch, headers: headers,
                                         body: .init(bytes: json)) { response in
                    #expect(response.status == .ok)
                    let product = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: String])
                    #expect(product["name"] == renamed)
                }
                let remaining = try await fixture.pool.query("SELECT name FROM public.products WHERE facility_id=\(fixture.facilityB) AND id=\(fixture.product)").collect()
                for row in remaining { #expect(try row.decode(String.self) == "Synthetic B") }
            }
        }
    }
}
