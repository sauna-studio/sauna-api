import Foundation
import HTTPTypes
import HummingbirdTesting
import Logging
import PostgresNIO
@testable import SaunaAPIDatabase
import Testing
@testable import SaunaAPIIdentity
@testable import SaunaAPIServer

struct FacilityHTTPFixture: Sendable {
    let pool: PostgresClient
    let facilityA: UUID, facilityB: UUID, emptyFacility: UUID
    let product: UUID, onlyB: UUID
    let managerID: UUID
    let manager: SessionGrant, staff: SessionGrant, owner: SessionGrant, customer: SessionGrant
    var pathA: String { "/staff/facilities/\(facilityA)/products" }
    var pathB: String { "/staff/facilities/\(facilityB)/products" }
    func headers(_ grant: SessionGrant) -> HTTPFields {
        [.origin: "http://localhost:5174", .cookie: "__Host-sauna-staff-session=" + grant.token.encoded,
         HTTPField.Name("X-Sauna-CSRF")!: grant.session.csrfToken, .contentType: "application/json"]
    }
}

func withFacilityHTTPFixture(_ body: @escaping @Sendable (FacilityHTTPFixture) async throws -> Void) async throws {
    var env = ProcessInfo.processInfo.environment
    env["PGDATABASE"] = "sauna_atlas_replay"
    let config = try LocalDatabaseConfiguration(environment: env)
    try await LocalDatabase.withClient(configuration: config, timeout: .seconds(30)) { pool in
        let facilities = [UUID(), UUID(), UUID()]
        let users = [UUID(), UUID(), UUID(), UUID()]
        let credentials = users.map { _ in authRandomBytes() }
        let product = UUID(), onlyB = UUID()
        func cleanup() async throws {
            for facility in facilities {
                _ = try await pool.query("DELETE FROM public.product_offerings WHERE facility_id=\(facility)").collect()
                _ = try await pool.query("DELETE FROM public.products WHERE facility_id=\(facility)").collect()
                _ = try await pool.query("DELETE FROM public.facility_memberships WHERE facility_id=\(facility)").collect()
                _ = try await pool.query("DELETE FROM public.facilities WHERE id=\(facility)").collect()
            }
            for user in users {
                _ = try await pool.query("DELETE FROM public.auth_sessions WHERE user_id=\(user)").collect()
                _ = try await pool.query("DELETE FROM public.passkey_credentials WHERE user_id=\(user)").collect()
                _ = try await pool.query("DELETE FROM public.passkey_accounts WHERE user_id=\(user)").collect()
                _ = try await pool.query("DELETE FROM public.users WHERE id=\(user)").collect()
            }
        }
        do {
            for facility in facilities { _ = try await pool.query("INSERT INTO public.facilities(id,name,time_zone) VALUES (\(facility),'Synthetic HTTP fixture','Asia/Tokyo')").collect() }
            for (index, user) in users.enumerated() {
                let handle = authRandomBytes()
                _ = try await pool.query("INSERT INTO public.users(id) VALUES (\(user))").collect()
                _ = try await pool.query("INSERT INTO public.passkey_accounts(user_id,user_handle) VALUES (\(user),\(handle))").collect()
                _ = try await pool.query("INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up) VALUES (\(credentials[index]),\(user),\(handle),\(Data([0])),0,false,false)").collect()
            }
            for (facility, user, role) in [(facilities[0],users[0],"manager"),(facilities[0],users[1],"staff"),(facilities[1],users[2],"owner"),(facilities[2],users[0],"manager")] {
                _ = try await pool.query("INSERT INTO public.facility_memberships(facility_id,user_id,role) VALUES (\(facility),\(user),\(role))").collect()
            }
            for (facility, id, name) in [(facilities[0],product,"Synthetic A"),(facilities[1],product,"Synthetic B"),(facilities[1],onlyB,"Synthetic B only")] {
                _ = try await pool.query("INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor) VALUES (\(facility),\(id),'private_sauna',\(name),'JPY',1000)").collect()
            }
            // These fixtures use the module-internal issuer, not an HTTP login or
            // an additional production authentication path. Cryptographic login
            // is independently exercised by AuthenticationStore/Management tests.
            var grants: [SessionGrant] = []
            for (index, user) in users.enumerated() {
                let grant = try await pool.withConnection { connection in
                    try await SessionStore.issue(on: connection, userID: user, credentialID: credentials[index], relyingParty: index == 3 ? .customer : .staff, ttlSeconds: 300)
                }
                grants.append(grant)
            }
            try await body(.init(pool: pool, facilityA: facilities[0], facilityB: facilities[1], emptyFacility: facilities[2], product: product, onlyB: onlyB, managerID: users[0], manager: grants[0], staff: grants[1], owner: grants[2], customer: grants[3]))
            try await cleanup()
        } catch { try await cleanup(); throw error }
    }
}

struct FacilityHTTPTests {
    @Test func unavailableSessionlessServiceAndCustomerOriginFailClosed() async throws {
        let app = try makeApplication(configuration: .init())
        let path = "/staff/facilities/\(UUID())/products"
        try await app.test(.live) { client in
            for (origin, status) in [("http://localhost:5174", HTTPResponse.Status.serviceUnavailable), ("http://localhost:5173", .forbidden), ("http://attacker.invalid", .forbidden)] {
                try await client.execute(uri: path, method: .get, headers: [.origin: origin]) { response in
                    #expect(response.status == status)
                    #expect(response.headers[.cacheControl] == "no-store")
                    #expect(response.headers[.setCookie] == nil)
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func realHTTPProductsRequireCurrentMembershipRoleAndCompositeFacility() async throws {
        try await withFacilityHTTPFixture { fixture in
            let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: fixture.pool))
            try await app.test(.live) { client in
                let headers = fixture.headers(fixture.manager)
                try await client.execute(uri: fixture.pathA, method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                    let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: [[String: String]]])
                    #expect(object["products"]?.map { $0["name"] } == ["Synthetic A"])
                    #expect(response.headers[.cacheControl] == "no-store")
                }
                try await client.execute(uri: "/staff/facilities/\(fixture.emptyFacility)/products", method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                    let value = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: [[String: String]]])
                    #expect(value["products"]?.isEmpty == true)
                }
                for (path, grant, expected) in [
                    (fixture.pathA + "/\(fixture.product)",fixture.staff,HTTPResponse.Status.ok),
                    (fixture.pathB + "/\(fixture.product)",fixture.owner,.ok),
                    (fixture.pathB,fixture.manager,.notFound),
                    (fixture.pathA + "/\(fixture.onlyB)",fixture.manager,.notFound),
                    (fixture.pathA + "/\(UUID())",fixture.manager,.notFound),
                    ("/staff/facilities/\(UUID())/products",fixture.manager,.notFound),
                    (fixture.pathA,fixture.customer,.unauthorized),
                ] {
                    try await client.execute(uri: path, method: .get, headers: fixture.headers(grant)) { response in
                        #expect(response.status == expected)
                        #expect(response.headers[.cacheControl] == "no-store")
                        if expected == .notFound {
                            let fixed = String(decoding: response.body.readableBytesView, as: UTF8.self) == "{\"type\":\"about:blank\",\"title\":\"Not Found\",\"status\":404}"
                            #expect(fixed)
                        }
                    }
                }
                try await client.execute(uri: fixture.pathA, method: .get, headers: [.origin: "http://localhost:5174"]) { response in #expect(response.status == .unauthorized) }
                let path = fixture.pathA + "/\(fixture.product)"
                try await client.execute(uri: path, method: .patch, headers: headers, body: .init(string: "{\"name\":\" Changed A \"}")) { response in
                    #expect(response.status == .ok)
                    let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: String])
                    #expect(object["name"] == "Changed A")
                }
                for (target, grant) in [(path,fixture.staff),(fixture.pathB + "/\(fixture.product)",fixture.manager),(fixture.pathA + "/\(fixture.onlyB)",fixture.manager)] {
                    try await client.execute(uri: target, method: .patch, headers: fixture.headers(grant), body: .init(string: "{\"name\":\"Forbidden\"}")) { response in #expect(response.status == .notFound) }
                }
                for body in ["{\"name\":\"one\",\"name\":\"two\"}","{\"name\":\"one\",\"na\\u006de\":\"two\"}","{\"name\":\"one\",\"facilityID\":\"foreign\"}","{}","{\"name\":123}","{\"name\":\"   \"}"] {
                    try await client.execute(uri: path, method: .patch, headers: headers, body: .init(string: body)) { response in #expect(response.status == .badRequest) }
                }
                var bad = headers; bad[HTTPField.Name("X-Sauna-CSRF")!] = String(repeating: "B", count: 43)
                try await client.execute(uri: path, method: .patch, headers: bad, body: .init(string: "{\"name\":\"Forbidden\"}")) { response in #expect(response.status == .unauthorized) }
                bad = headers; bad[HTTPField.Name("X-Sauna-CSRF")!] = nil
                try await client.execute(uri: path, method: .patch, headers: bad, body: .init(string: "{\"name\":\"Forbidden\"}")) { response in #expect(response.status == .badRequest) }
                for limit in ["0","101","-1"] {
                    try await client.execute(uri: fixture.pathA + "?limit=" + limit, method: .get, headers: headers) { response in #expect(response.status == .badRequest) }
                }
                _ = try await fixture.pool.query("UPDATE public.facility_memberships SET role='staff' WHERE facility_id=\(fixture.facilityA) AND user_id=\(fixture.managerID)").collect()
                try await client.execute(uri: path, method: .patch, headers: headers, body: .init(string: "{\"name\":\"Forbidden\"}")) { response in #expect(response.status == .notFound) }
                _ = try await fixture.pool.query("UPDATE public.facility_memberships SET status='revoked' WHERE facility_id=\(fixture.facilityA) AND user_id=\(fixture.managerID)").collect()
                try await client.execute(uri: fixture.pathA, method: .get, headers: headers) { response in #expect(response.status == .notFound) }
                let rows = try await fixture.pool.query("SELECT name FROM public.products WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product)")
                for try await name in rows.decode(String.self) { #expect(name == "Changed A") }
                let other = try await fixture.pool.query("SELECT name FROM public.products WHERE facility_id=\(fixture.facilityB) AND id=\(fixture.product)")
                for try await name in other.decode(String.self) { #expect(name == "Synthetic B") }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func constructedServiceRechecksSessionExpiryRevocationAndCredentialRevocation() async throws {
        try await withFacilityHTTPFixture { fixture in
            let service = FacilityService(client: fixture.pool, token: fixture.manager.token, relyingParty: .staff)
            let value = try await service.product(facilityID: fixture.facilityA, id: fixture.product)
            #expect(value.name == "Synthetic A")
            _ = try await fixture.pool.query("UPDATE public.auth_sessions SET revoked_at=clock_timestamp() WHERE token_hash=\(fixture.manager.token.digest)").collect()
            do { _ = try await service.listProducts(facilityID: fixture.facilityA); Issue.record("Revoked session must reject the next operation") }
            catch { #expect(error as? AuthenticationError == .rejected) }
            let staffService = FacilityService(client: fixture.pool, token: fixture.staff.token, relyingParty: .staff)
            _ = try await fixture.pool.query("UPDATE public.auth_sessions SET created_at=clock_timestamp()-interval '1 hour',expires_at=clock_timestamp()-interval '1 second' WHERE token_hash=\(fixture.staff.token.digest)").collect()
            do { _ = try await staffService.product(facilityID: fixture.facilityA, id: fixture.product); Issue.record("Expired session must reject the next operation") }
            catch { #expect(error as? AuthenticationError == .rejected) }
            let ownerService = FacilityService(client: fixture.pool, token: fixture.owner.token, relyingParty: .staff)
            _ = try await fixture.pool.query("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE user_id=\(fixture.owner.session.subject.userID)").collect()
            do { _ = try await ownerService.product(facilityID: fixture.facilityB, id: fixture.product); Issue.record("Revoked credential must reject the next operation") }
            catch { #expect(error as? AuthenticationError == .rejected) }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func boundStatementRechecksSessionAfterInitialResolution() async throws {
        try await withFacilityHTTPFixture { fixture in
            let session = try await SessionStore(client: fixture.pool, relyingParty: .staff).resolve(token: fixture.manager.token)
            try await fixture.pool.withConnection { connection in
                let store = FacilityStore(connection: connection, subject: session.subject, facilityID: fixture.facilityA,
                                          sessionToken: fixture.manager.token, relyingParty: .staff)
                let original = try await store.product(id: fixture.product)
                #expect(original.name == "Synthetic A")
                for state in 0..<4 {
                    _ = try await connection.query("UPDATE public.auth_sessions SET revoked_at=NULL,created_at=clock_timestamp(),expires_at=clock_timestamp()+interval '5 minutes' WHERE token_hash=\(fixture.manager.token.digest)", logger: .init(label: "Fixture", factory: { _ in SwiftLogNoOpLogHandler() })).collect()
                    _ = try await connection.query("UPDATE public.passkey_credentials SET revoked_at=NULL WHERE user_id=\(fixture.managerID)", logger: .init(label: "Fixture", factory: { _ in SwiftLogNoOpLogHandler() })).collect()
                    let logger = Logger(label: "Fixture") { _ in SwiftLogNoOpLogHandler() }
                    switch state {
                    case 0: _ = try await connection.query("UPDATE public.auth_sessions SET revoked_at=clock_timestamp() WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    case 1: _ = try await connection.query("UPDATE public.auth_sessions SET created_at=clock_timestamp()-interval '1 hour',expires_at=clock_timestamp()-interval '1 second' WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    case 2: _ = try await connection.query("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE user_id=\(fixture.managerID)", logger: logger).collect()
                    default: _ = try await connection.query("UPDATE public.auth_sessions SET origin='http://localhost:5173' WHERE token_hash=\(fixture.manager.token.digest)", logger: logger).collect()
                    }
                    do { _ = try await store.listProducts(); Issue.record("Bound list must reject stale session") }
                    catch { #expect(error as? FacilityStoreError == .notAvailable) }
                    do { _ = try await store.product(id: fixture.product); Issue.record("Bound detail must reject stale session") }
                    catch { #expect(error as? FacilityStoreError == .notAvailable) }
                    do { _ = try await store.renameProduct(id: fixture.product, name: "Forbidden"); Issue.record("Bound update must reject stale session") }
                    catch { #expect(error as? FacilityStoreError == .notAvailable) }
                }
                let rows = try await connection.query("SELECT name FROM public.products WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product)", logger: .init(label: "Fixture", factory: { _ in SwiftLogNoOpLogHandler() }))
                for try await name in rows.decode(String.self) { #expect(name == "Synthetic A") }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func blockedUpdateDeadlineClosesOnlyItsLeaseAndNeverCommitsLate() async throws {
        try await withFacilityHTTPFixture { fixture in
            let service = FacilityService(client: fixture.pool, token: fixture.manager.token, relyingParty: .staff)
            try await fixture.pool.withConnection { blocker in
                let logger = Logger(label: "Fixture") { _ in SwiftLogNoOpLogHandler() }
                _ = try await blocker.query("BEGIN", logger: logger).collect()
                do {
                    _ = try await blocker.query("SELECT id FROM public.products WHERE facility_id=\(fixture.facilityA) AND id=\(fixture.product) FOR UPDATE", logger: logger).collect()
                    let clock = ContinuousClock()
                    let start = clock.now
                    do {
                        _ = try await service.renameProduct(facilityID: fixture.facilityA, id: fixture.product, name: "Forbidden late change", csrfToken: fixture.manager.session.csrfToken)
                        Issue.record("A blocked update must reach the bounded deadline")
                    } catch { #expect(error as? AuthenticationError == .unavailable) }
                    #expect(start.duration(to: clock.now) < .seconds(15))
                    _ = try await blocker.query("ROLLBACK", logger: logger).collect()
                } catch {
                    _ = try await blocker.query("ROLLBACK", logger: logger).collect()
                    throw error
                }
            }
            let unchanged = try await service.product(facilityID: fixture.facilityA, id: fixture.product)
            #expect(unchanged.name == "Synthetic A")
        }
    }

}
