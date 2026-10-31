import Foundation
import Logging
import PostgresNIO
import Testing
@testable import SaunaAPIDatabase
@testable import SaunaAPIIdentity

private let fixtureLogger = Logger(label: "SaunaFacilityTests") { _ in SwiftLogNoOpLogHandler() }

private struct FacilityFixture: Sendable {
    let connection: PostgresConnection
    let facilityA: UUID
    let facilityB: UUID
    let emptyFacility: UUID
    let manager: VerifiedSubject
    let staff: VerifiedSubject
    let owner: VerifiedSubject
    let customer: VerifiedSubject
    let revoked: VerifiedSubject
    let sharedProduct: UUID
    let onlyBProduct: UUID

    func store(_ subject: VerifiedSubject, _ facility: UUID) -> FacilityStore {
        .init(connection: connection, subject: subject, facilityID: facility)
    }
}

private func execute(_ query: PostgresQuery, on connection: PostgresConnection) async throws {
    _ = try await connection.query(query, logger: fixtureLogger).collect()
}

private func withFacilityFixture(_ body: @escaping @Sendable (FacilityFixture) async throws -> Void) async throws {
    let configuration = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
    try await LocalDatabase.withClient(configuration: configuration, timeout: .seconds(20)) { client in
        try await client.withConnection { connection in
            // Pin all fixture SQL and store queries to the same transaction. No
            // fixture commits or cleanup deletes ever touch persistent rows.
            try await execute("BEGIN ISOLATION LEVEL READ COMMITTED", on: connection)
            do {
                let facilities = [UUID(), UUID(), UUID()]
                let people = (0..<5).map { _ in VerifiedSubject(userID: UUID()) }
                let product = UUID()
                let onlyB = UUID()
                for facility in facilities {
                    try await execute("INSERT INTO public.facilities(id,name,time_zone) VALUES (\(facility),'Synthetic fixture','Asia/Tokyo')", on: connection)
                }
                for person in people {
                    try await execute("INSERT INTO public.users(id) VALUES (\(person.userID))", on: connection)
                }
                try await execute("INSERT INTO public.facility_memberships(facility_id,user_id,role) VALUES (\(facilities[0]),\(people[0].userID),'manager')", on: connection)
                try await execute("INSERT INTO public.facility_memberships(facility_id,user_id,role) VALUES (\(facilities[0]),\(people[1].userID),'staff')", on: connection)
                try await execute("INSERT INTO public.facility_memberships(facility_id,user_id,role) VALUES (\(facilities[1]),\(people[2].userID),'owner')", on: connection)
                try await execute("INSERT INTO public.facility_memberships(facility_id,user_id,role,status) VALUES (\(facilities[0]),\(people[4].userID),'manager','revoked')", on: connection)
                try await execute("INSERT INTO public.facility_memberships(facility_id,user_id,role) VALUES (\(facilities[2]),\(people[0].userID),'manager')", on: connection)
                for (facility, name) in [(facilities[0], "Synthetic A"), (facilities[1], "Synthetic B")] {
                    try await execute("INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor) VALUES (\(facility),\(product),'private_sauna',\(name),'JPY',1000)", on: connection)
                }
                try await execute("INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor) VALUES (\(facilities[1]),\(onlyB),'day_tent','Synthetic B only','JPY',2000)", on: connection)
                let fixture = FacilityFixture(connection: connection, facilityA: facilities[0], facilityB: facilities[1], emptyFacility: facilities[2], manager: people[0], staff: people[1], owner: people[2], customer: people[3], revoked: people[4], sharedProduct: product, onlyBProduct: onlyB)
                try await body(fixture)
                try await execute("ROLLBACK", on: connection)
                let rows = try await connection.query("SELECT count(*) FROM public.facilities WHERE id=\(facilities[0]) OR id=\(facilities[1]) OR id=\(facilities[2])", logger: fixtureLogger)
                for try await count in rows.decode(Int.self) { #expect(count == 0) }
            } catch {
                try await execute("ROLLBACK", on: connection)
                throw error
            }
        }
    }
}

private func expectStoreError<Value>(_ expected: FacilityStoreError, _ operation: () async throws -> Value) async {
    do {
        _ = try await operation()
        Issue.record("Expected fixed facility store rejection")
    } catch {
        #expect(error as? FacilityStoreError == expected)
        #expect(String(describing: error) == expected.description)
    }
}

struct FacilityStoreTests {
    @Test func subjectDescriptionIsRedacted() {
        let subject = VerifiedSubject(userID: UUID())
        #expect(String(describing: subject) == "VerifiedSubject(<redacted>)")
        #expect(String(reflecting: subject) == "VerifiedSubject(<redacted>)")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func publicPoolExecutorDeniesUnassociatedSubjectWithoutMutations() async throws {
        let configuration = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
        try await LocalDatabase.withClient(configuration: configuration) { client in
            let store = FacilityStore(client: client, subject: VerifiedSubject(userID: UUID()), facilityID: UUID())
            await expectStoreError(.notAvailable) { try await store.listProducts() }
            await expectStoreError(.notAvailable) { try await store.product(id: UUID()) }
            await expectStoreError(.notAvailable) { try await store.renameProduct(id: UUID(), name: "Synthetic denied change") }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func readsAreScopedToMembershipAndCompositeProductKey() async throws {
        try await withFacilityFixture { fixture in
            let managerA = fixture.store(fixture.manager, fixture.facilityA)
            let staffA = fixture.store(fixture.staff, fixture.facilityA)
            let ownerB = fixture.store(fixture.owner, fixture.facilityB)
            let assertion1 = try await managerA.listProducts().map(\.name) == ["Synthetic A"]
            #expect(assertion1)
            let assertion2 = try await staffA.product(id: fixture.sharedProduct).name == "Synthetic A"
            #expect(assertion2)
            let assertion3 = try await ownerB.product(id: fixture.sharedProduct).name == "Synthetic B"
            #expect(assertion3)
            let assertion4 = try await fixture.store(fixture.manager, fixture.emptyFacility).listProducts().isEmpty
            #expect(assertion4)
            await expectStoreError(.notAvailable) { try await managerA.product(id: fixture.onlyBProduct) }
            for denied in [fixture.store(fixture.manager, fixture.facilityB), fixture.store(fixture.customer, fixture.facilityA), fixture.store(fixture.revoked, fixture.facilityA), fixture.store(fixture.manager, UUID())] {
                await expectStoreError(.notAvailable) { try await denied.listProducts() }
                await expectStoreError(.notAvailable) { try await denied.product(id: fixture.sharedProduct) }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func updatesRequireCurrentManagerOrOwnerAndNeverCrossFacility() async throws {
        try await withFacilityFixture { fixture in
            let managerA = fixture.store(fixture.manager, fixture.facilityA)
            let ownerB = fixture.store(fixture.owner, fixture.facilityB)
            let assertion5 = try await managerA.renameProduct(id: fixture.sharedProduct, name: " Changed A ").name == "Changed A"
            #expect(assertion5)
            let assertion6 = try await ownerB.product(id: fixture.sharedProduct).name == "Synthetic B"
            #expect(assertion6)
            // Parameter interpolation must bind the value as data, not executable SQL.
            let quoted = "Synthetic '; DROP TABLE products; --"
            let assertion7 = try await ownerB.renameProduct(id: fixture.sharedProduct, name: quoted).name == quoted
            #expect(assertion7)
            let assertion8 = try await managerA.product(id: fixture.sharedProduct).name == "Changed A"
            #expect(assertion8)
            await expectStoreError(.notAvailable) { try await managerA.renameProduct(id: fixture.onlyBProduct, name: "Forbidden") }
            for denied in [fixture.store(fixture.staff, fixture.facilityA), fixture.store(fixture.customer, fixture.facilityA), fixture.store(fixture.revoked, fixture.facilityA), fixture.store(fixture.manager, fixture.facilityB)] {
                await expectStoreError(.notAvailable) { try await denied.renameProduct(id: fixture.sharedProduct, name: "Forbidden") }
            }
            let assertion9 = try await managerA.product(id: fixture.sharedProduct).name == "Changed A"
            #expect(assertion9)
            let assertion10 = try await ownerB.product(id: fixture.sharedProduct).name == quoted
            #expect(assertion10)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func membershipChangesAreRecheckedAfterStoreConstruction() async throws {
        try await withFacilityFixture { fixture in
            let store = fixture.store(fixture.manager, fixture.facilityA)
            let assertion11 = try await store.product(id: fixture.sharedProduct).name == "Synthetic A"
            #expect(assertion11)
            try await execute("UPDATE public.facility_memberships SET role='staff' WHERE facility_id=\(fixture.facilityA) AND user_id=\(fixture.manager.userID)", on: fixture.connection)
            await expectStoreError(.notAvailable) { try await store.renameProduct(id: fixture.sharedProduct, name: "Forbidden") }
            let assertion12 = try await store.listProducts().count == 1
            #expect(assertion12)
            try await execute("UPDATE public.facility_memberships SET status='revoked' WHERE facility_id=\(fixture.facilityA) AND user_id=\(fixture.manager.userID)", on: fixture.connection)
            await expectStoreError(.notAvailable) { try await store.listProducts() }
            await expectStoreError(.notAvailable) { try await store.product(id: fixture.sharedProduct) }
            await expectStoreError(.notAvailable) { try await store.renameProduct(id: fixture.sharedProduct, name: "Forbidden") }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func invalidInputsAreFixedAndDoNotModifyCatalog() async throws {
        try await withFacilityFixture { fixture in
            let store = fixture.store(fixture.manager, fixture.facilityA)
            for limit in [0, -1, 101, Int.max] {
                await expectStoreError(.invalidInput) { try await store.listProducts(limit: limit) }
            }
            for name in ["", " \t\n", "contains\0nul", String(repeating: "a", count: 201), String(repeating: "e\u{301}", count: 101)] {
                await expectStoreError(.invalidInput) { try await store.renameProduct(id: fixture.sharedProduct, name: name) }
            }
            let assertion13 = try await store.product(id: fixture.sharedProduct).name == "Synthetic A"
            #expect(assertion13)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires explicit local PostgreSQL password file"))
    func poolLifetimePreservesClosedDomainRejections() async throws {
        let configuration = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
        do {
            _ = try await LocalDatabase.withClient(configuration: configuration) { client in
                try await FacilityStore(client: client, subject: VerifiedSubject(userID: UUID()), facilityID: UUID()).listProducts()
            }
            Issue.record("Expected fixed facility rejection outside pool lifetime")
        } catch { #expect(error as? FacilityStoreError == .notAvailable) }
        do {
            _ = try await LocalDatabase.withClient(configuration: configuration) { client in
                try await PasskeyChallengeStore(client: client, relyingParty: .customer).consume(id: UUID(), purpose: .authentication, binding: .generate())
            }
            Issue.record("Expected fixed challenge rejection outside pool lifetime")
        } catch { #expect(error as? PasskeyChallengeError == .notAvailable) }
    }

}
