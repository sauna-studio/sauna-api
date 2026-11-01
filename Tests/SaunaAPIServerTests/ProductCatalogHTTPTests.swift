import Foundation
import HTTPTypes
import HummingbirdTesting
import Logging
import PostgresNIO
import Testing
@testable import SaunaAPIDatabase
@testable import SaunaAPIIdentity
@testable import SaunaAPIServer

private struct CatalogFixture: Sendable {
    let products: [UUID]
    let draft: UUID
    let unconfigured: UUID
}

private func conditions(_ kind: ProductKind, capacity: Int = 6) throws -> ProductConditions {
    try .init(kind: kind, capacity: capacity, minimumDurationMinutes: kind == .overnightTent ? 720 : 30,
              maximumDurationMinutes: kind == .overnightTent ? 10080 : 300,
              minimumNights: kind == .overnightTent ? 1 : 0, maximumNights: kind == .overnightTent ? 7 : 0)
}
private func catalogBody(kind: ProductKind = .privateSauna, published: Bool = true, capacity: Int = 6) throws -> String {
    let value = try conditions(kind, capacity: capacity)
    return String(decoding: try JSONSerialization.data(withJSONObject: [
        "kind":kind.rawValue,"capacity":value.capacity,"minimumDurationMinutes":value.minimumDurationMinutes,
        "maximumDurationMinutes":value.maximumDurationMinutes,"minimumNights":value.minimumNights,
        "maximumNights":value.maximumNights,"published":published]), as: UTF8.self)
}
private func configureCatalog(_ fixture: FacilityHTTPFixture) async throws -> CatalogFixture {
    let products = [fixture.product,UUID(),UUID(),UUID()]
    let service = FacilityService(client: fixture.pool, token: fixture.manager.token, relyingParty: .staff)
    for (index, kind) in ProductKind.allCases.enumerated() {
        if index > 0 {
            _ = try await fixture.pool.query("INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor) VALUES (\(fixture.facilityA),\(products[index]),\(kind.rawValue),'Synthetic catalog kind','JPY',0)").collect()
        }
        _ = try await service.setOffering(facilityID: fixture.facilityA, id: products[index], conditions: conditions(kind), published: true, csrfToken: fixture.manager.session.csrfToken)
    }
    let draft = UUID(), unconfigured = UUID()
    for (id, published) in [(draft,false),(unconfigured,true)] {
        _ = try await fixture.pool.query("INSERT INTO public.products(facility_id,id,kind,name,published,currency,unit_price_minor) VALUES (\(fixture.facilityA),\(id),'day_tent','Synthetic unlisted product',\(published),'JPY',0)").collect()
    }
    _ = try await service.setOffering(facilityID: fixture.facilityA, id: draft, conditions: conditions(.dayTent), published: false, csrfToken: fixture.manager.session.csrfToken)
    let owner = FacilityService(client: fixture.pool, token: fixture.owner.token, relyingParty: .staff)
    _ = try await owner.setOffering(facilityID: fixture.facilityB, id: fixture.product, conditions: conditions(.privateSauna), published: true, csrfToken: fixture.owner.session.csrfToken)
    _ = try await owner.setOffering(facilityID: fixture.facilityB, id: fixture.onlyB, conditions: conditions(.privateSauna), published: false, csrfToken: fixture.owner.session.csrfToken)
    return .init(products: products, draft: draft, unconfigured: unconfigured)
}
private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct ProductCatalogHTTPTests {
    @Test func anonymousCatalogIsExplicitAndDoesNotRelaxStaffAuthentication() async throws {
        let app = try makeApplication(configuration: .init())
        let facility = UUID(), product = UUID()
        try await app.test(.live) { client in
            try await client.execute(uri: "/facilities/\(facility)/products", method: .get) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.setCookie] == nil)
            }
            try await client.execute(uri: "/staff/facilities/\(facility)/offerings", method: .get) { response in #expect(response.status == .forbidden) }
            try await client.execute(uri: "/staff/facilities/\(facility)/products/\(product)/offering", method: .put,
                                     body: .init(string: try catalogBody())) { response in #expect(response.status == .forbidden) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated local PostgreSQL password file"))
    func anonymousFourKindCatalogIsPublishedConfiguredAndFacilityScoped() async throws {
        try await withFacilityHTTPFixture { fixture in
            let configured = try await configureCatalog(fixture)
            let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: fixture.pool))
            let path = "/facilities/\(fixture.facilityA)/products"
            try await app.test(.live) { client in
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .ok)
                    let values = try #require(try object(Data(response.body.readableBytesView))["products"] as? [[String: Any]])
                    #expect(values.count == 4)
                    let kinds = Set(values.compactMap { $0["kind"] as? String })
                    #expect(kinds == Set(ProductKind.allCases.map(\.rawValue)))
                    for value in values {
                        #expect(Set(value.keys) == ["facilityID","id","name","kind","capacity","minimumDurationMinutes","maximumDurationMinutes","minimumNights","maximumNights","published"])
                        #expect(value["facilityID"] as? String == fixture.facilityA.uuidString)
                        #expect(value["published"] as? Bool == true)
                    }
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.setCookie] == nil)
                }
                for (index, kind) in ProductKind.allCases.enumerated() {
                    try await client.execute(uri: path + "?kind=" + kind.rawValue, method: .get) { response in
                        #expect(response.status == .ok)
                        let values = try #require(try object(Data(response.body.readableBytesView))["products"] as? [[String: Any]])
                        #expect(values.count == 1)
                        #expect(values.first?["kind"] as? String == kind.rawValue)
                    }
                    try await client.execute(uri: path + "/\(configured.products[index])", method: .get) { response in
                        #expect(response.status == .ok)
                        let value = try object(Data(response.body.readableBytesView))
                        #expect(value["kind"] as? String == kind.rawValue)
                        #expect(value["capacity"] as? Int == 6)
                    }
                }
                for id in [configured.draft,configured.unconfigured,fixture.onlyB,UUID()] {
                    try await client.execute(uri: path + "/\(id)", method: .get) { response in
                        #expect(response.status == .notFound)
                        let fixed = String(decoding: response.body.readableBytesView, as: UTF8.self) == "{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404}"
                        #expect(fixed)
                    }
                }
                try await client.execute(uri: "/facilities/\(fixture.facilityB)/products/\(fixture.product)", method: .get) { response in
                    #expect(response.status == .ok)
                    let value = try object(Data(response.body.readableBytesView))
                    #expect(value["name"] as? String == "Synthetic B")
                }
                for facility in [fixture.emptyFacility,UUID()] {
                    try await client.execute(uri: "/facilities/\(facility)/products", method: .get) { response in
                        #expect(response.status == .ok)
                        let values = try #require(try object(Data(response.body.readableBytesView))["products"] as? [[String: Any]])
                        #expect(values.isEmpty)
                    }
                }
                for query in ["published=false","publication=draft","userID=anything","kind=private_sauna&kind=day_tent","%6bind=private_sauna&kind=day_tent","limit=0","limit=101","limit=-1","kind=unknown","limit=1&limit=2","kind="] {
                    try await client.execute(uri: path + "?" + query, method: .get) { response in #expect(response.status == .badRequest) }
                }
                try await client.execute(uri: path + "?limit=1", method: .get, headers: [.cookie: "__Host-sauna-staff-session=not-authority"]) { response in
                    #expect(response.status == .ok)
                    let values = try #require(try object(Data(response.body.readableBytesView))["products"] as? [[String: Any]])
                    #expect(values.count == 1)
                }
                try await client.execute(uri: path, method: .get, body: .init(string: "private-marker")) { response in #expect(response.status == .badRequest) }
                // The existing SQL constraint bounds btrim(name), which can
                // admit a raw string longer than the public wire contract.
                let overlongName = String(repeating: "a", count: 200) + " "
                _ = try await fixture.pool.query("UPDATE public.products SET name=\(overlongName) WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product)").collect()
                for target in [path, path + "/\(fixture.product)"] {
                    try await client.execute(uri: target, method: .get) { response in
                        #expect(response.status == .serviceUnavailable)
                        let redacted = !String(decoding: response.body.readableBytesView, as: UTF8.self).contains(overlongName)
                        #expect(redacted)
                    }
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated local PostgreSQL password file"))
    func staffFiltersAndAtomicConditionsPublicationRespectRoleAndCSRF() async throws {
        try await withFacilityHTTPFixture { fixture in
            let configured = try await configureCatalog(fixture)
            let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: fixture.pool))
            let list = "/staff/facilities/\(fixture.facilityA)/offerings"
            let path = fixture.pathA + "/\(fixture.product)/offering"
            let headers = fixture.headers(fixture.manager)
            try await app.test(.live) { client in
                for (query, expected) in [("",5),("?publication=draft",1),("?publication=published",4),("?kind=overnight_tent",1)] {
                    try await client.execute(uri: list + query, method: .get, headers: fixture.headers(fixture.staff)) { response in
                        #expect(response.status == .ok)
                        let values = try #require(try object(Data(response.body.readableBytesView))["products"] as? [[String: Any]])
                        #expect(values.count == expected)
                    }
                }
                try await client.execute(uri: fixture.pathA + "/\(configured.draft)/offering", method: .get, headers: fixture.headers(fixture.staff)) { response in #expect(response.status == .ok) }
                for target in ["/staff/facilities/\(fixture.facilityB)/offerings",fixture.pathB + "/\(fixture.product)/offering"] {
                    try await client.execute(uri: target, method: .get, headers: headers) { response in #expect(response.status == .notFound) }
                }
                for target in [fixture.pathB + "/\(fixture.product)/offering", fixture.pathA + "/\(fixture.onlyB)/offering"] {
                    try await client.execute(uri: target, method: .put, headers: headers, body: .init(string: try catalogBody(published: false))) { response in #expect(response.status == .notFound) }
                }
                for grant in [fixture.staff,fixture.customer] {
                    try await client.execute(uri: path, method: .put, headers: fixture.headers(grant), body: .init(string: try catalogBody(published: false))) { response in
                        #expect(response.status == (grant.session.subject.userID == fixture.staff.session.subject.userID ? .notFound : .unauthorized))
                    }
                }
                var noCSRF = headers; noCSRF[HTTPField.Name("X-Sauna-CSRF")!] = nil
                try await client.execute(uri: path, method: .put, headers: noCSRF, body: .init(string: try catalogBody())) { response in #expect(response.status == .badRequest) }
                var wrongCSRF = headers; wrongCSRF[HTTPField.Name("X-Sauna-CSRF")!] = String(repeating: "B", count: 43)
                try await client.execute(uri: path, method: .put, headers: wrongCSRF, body: .init(string: try catalogBody())) { response in #expect(response.status == .unauthorized) }
                let original = try catalogBody()
                for body in [original.replacing("\"capacity\":6", with: "\"capacity\":0"),original.replacing("\"minimumNights\":0", with: "\"minimumNights\":1"),original.dropLast() + ",\"capacity\":7}",original.dropLast() + ",\"capaci\\u0074y\":7}",original.dropLast() + ",\"userID\":\"foreign\"}"] {
                    try await client.execute(uri: path, method: .put, headers: headers, body: .init(string: String(body))) { response in #expect(response.status == .badRequest) }
                }
                try await client.execute(uri: path, method: .put, headers: headers, body: .init(string: try catalogBody(kind: .sharedSauna, published: false))) { response in #expect(response.status == .notFound) }
                try await client.execute(uri: path, method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                    let value = try object(Data(response.body.readableBytesView))
                    #expect(value["published"] as? Bool == true)
                    #expect(value["capacity"] as? Int == 6)
                }
                try await client.execute(uri: path, method: .put, headers: headers, body: .init(string: try catalogBody(published: false, capacity: 9))) { response in
                    #expect(response.status == .ok)
                    let value = try object(Data(response.body.readableBytesView))
                    #expect(value["published"] as? Bool == false)
                    #expect(value["capacity"] as? Int == 9)
                }
                try await client.execute(uri: "/facilities/\(fixture.facilityA)/products/\(fixture.product)", method: .get) { response in #expect(response.status == .notFound) }
                try await client.execute(uri: path, method: .put, headers: headers, body: .init(string: try catalogBody(published: true, capacity: 10))) { response in #expect(response.status == .ok) }
                try await client.execute(uri: "/facilities/\(fixture.facilityA)/products/\(fixture.product)", method: .get) { response in
                    #expect(response.status == .ok)
                    let value = try object(Data(response.body.readableBytesView))
                    #expect(value["capacity"] as? Int == 10)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated local PostgreSQL password file"))
    func boundOfferingStatementsRejectStaleSessionAndCannotPartiallyPublish() async throws {
        try await withFacilityHTTPFixture { fixture in
            _ = try await configureCatalog(fixture)
            try await fixture.pool.withConnection { connection in
                let logger = Logger(label: "CatalogFixture") { _ in SwiftLogNoOpLogHandler() }
                let store = ProductCatalogStore(connection: connection, subject: fixture.manager.session.subject, token: fixture.manager.token, party: .staff)
                for state in 0..<5 {
                    _ = try await connection.query("UPDATE public.auth_sessions SET origin='http://localhost:5174',revoked_at=NULL,created_at=clock_timestamp(),expires_at=clock_timestamp()+interval '5 minutes' WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    _ = try await connection.query("UPDATE public.passkey_credentials SET revoked_at=NULL WHERE user_id=\(fixture.managerID)", logger: logger).collect()
                    switch state {
                    case 0: _ = try await connection.query("UPDATE public.auth_sessions SET revoked_at=clock_timestamp() WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    case 1: _ = try await connection.query("UPDATE public.auth_sessions SET created_at=clock_timestamp()-interval '1 hour',expires_at=clock_timestamp()-interval '1 second' WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    case 2: _ = try await connection.query("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE user_id=\(fixture.managerID)", logger: logger).collect()
                    case 3: _ = try await connection.query("UPDATE public.auth_sessions SET origin='http://localhost:5173' WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    default: _ = try await connection.query("UPDATE public.facility_memberships SET status='revoked' WHERE facility_id=\(fixture.facilityA) AND user_id=\(fixture.managerID)", logger: logger).collect()
                    }
                    do { _ = try await store.staffProducts(facilityID: fixture.facilityA, kind: nil, published: nil, limit: 100); Issue.record("Stale session cannot list draft conditions") }
                    catch { #expect(error as? FacilityStoreError == .notAvailable) }
                    do { _ = try await store.staffProduct(facilityID: fixture.facilityA, id: fixture.product); Issue.record("Stale session cannot read draft conditions") }
                    catch { #expect(error as? FacilityStoreError == .notAvailable) }
                    do { _ = try await store.setOffering(facilityID: fixture.facilityA, id: fixture.product, conditions: conditions(.privateSauna, capacity: 9), published: false); Issue.record("Stale session cannot change conditions/publication") }
                    catch { #expect(error as? FacilityStoreError == .notAvailable) }
                }
                _ = try await connection.query("UPDATE public.facility_memberships SET status='active',role='staff' WHERE facility_id=\(fixture.facilityA) AND user_id=\(fixture.managerID)", logger: logger).collect()
                let readable = try await store.staffProduct(facilityID: fixture.facilityA, id: fixture.product)
                #expect(readable.conditions.capacity == 6)
                do { _ = try await store.setOffering(facilityID: fixture.facilityA, id: fixture.product, conditions: conditions(.privateSauna, capacity: 9), published: false); Issue.record("Role downgrade must reject configuration updates") }
                catch { #expect(error as? FacilityStoreError == .notAvailable) }
                let value = try await store.publishedProduct(facilityID: fixture.facilityA, id: fixture.product)
                #expect(value.published)
                #expect(value.conditions.capacity == 6)
            }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated local PostgreSQL password file"))
    func blockedOfferingUpdateCannotCommitTermsOrPublicationAfterDeadline() async throws {
        try await withFacilityHTTPFixture { fixture in
            _ = try await configureCatalog(fixture)
            let service = FacilityService(client: fixture.pool, token: fixture.manager.token, relyingParty: .staff)
            try await fixture.pool.withConnection { blocker in
                let logger = Logger(label: "CatalogFixture") { _ in SwiftLogNoOpLogHandler() }
                _ = try await blocker.query("BEGIN", logger: logger).collect()
                do {
                    _ = try await blocker.query("SELECT id FROM public.products WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product) FOR UPDATE", logger: logger).collect()
                    do {
                        _ = try await service.setOffering(facilityID: fixture.facilityA, id: fixture.product,
                            conditions: conditions(.privateSauna, capacity: 9), published: false,
                            csrfToken: fixture.manager.session.csrfToken)
                        Issue.record("A blocked catalog update must reach its deadline")
                    } catch { #expect(error as? AuthenticationError == .unavailable) }
                    _ = try await blocker.query("ROLLBACK", logger: logger).collect()
                } catch {
                    _ = try await blocker.query("ROLLBACK", logger: logger).collect()
                    throw error
                }
            }
            let value = try await ProductCatalogService(client: fixture.pool).product(facilityID: fixture.facilityA, id: fixture.product)
            #expect(value.published)
            #expect(value.conditions.capacity == 6)
        }
    }

}
