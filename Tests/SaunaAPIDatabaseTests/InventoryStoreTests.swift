import Foundation
import Logging
import PostgresNIO
import Testing
@testable import SaunaAPIDatabase
@testable import SaunaAPIIdentity

private let inventoryLogger = Logger(label: "InventoryFixtures") { _ in SwiftLogNoOpLogHandler() }
private func sql(_ query: PostgresQuery, _ connection: PostgresConnection) async throws {
    _ = try await connection.query(query, logger: inventoryLogger).collect()
}

private struct InventoryFixture: Sendable {
    let pool: PostgresClient
    let facilities: [UUID]
    let users: [UUID]
    let credentials: [Data]
    let grants: [SessionGrant]
    let products: [UUID]
    let resources: [UUID]
    func service(_ index: Int = 0) -> InventoryService {
        .init(client: pool, token: grants[index].token, relyingParty: index == 3 ? .customer : .staff)
    }
    var csrf: String { grants[0].session.csrfToken }
    func interval(_ offset: TimeInterval = 0) throws -> InventoryInterval {
        try .init(startsAt: Date(timeIntervalSince1970: 2_000_000_000 + offset), endsAt: Date(timeIntervalSince1970: 2_000_003_600 + offset))
    }
    func allocate(_ kind: Int, seats: InventorySeats, offset: TimeInterval = 0) async throws -> InventoryClaim {
        try await service().allocate(facilityID: facilities[0], resourceID: resources[kind < 2 ? 0 : 1], productID: products[kind], interval: interval(offset), seats: seats, csrfToken: csrf)
    }
}

private func withInventoryFixture(_ body: @escaping @Sendable (InventoryFixture) async throws -> Void) async throws {
    let config = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
    try await LocalDatabase.withClient(configuration: config, timeout: .seconds(30)) { pool in
        let facilities = [UUID(), UUID()], users = (0..<4).map { _ in UUID() }
        let credentials = users.map { _ in authRandomBytes() }
        let products = (0..<4).map { _ in UUID() }, resources = [UUID(), UUID()]
        func cleanup() async throws {
            for facility in facilities {
                for table in ["inventory_claims", "inventory_product_resources", "inventory_resources", "product_offerings", "products", "facility_memberships"] {
                    // SQL identifiers cannot be bound; use this fixed table allowlist.
                    var binds = PostgresBindings()
                    binds.append(facility)
                    let query = PostgresQuery(unsafeSQL: "DELETE FROM public.\(table) WHERE facility_id=$1", binds: binds)
                    _ = try await pool.query(query).collect()
                }
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
            for facility in facilities { _ = try await pool.query("INSERT INTO public.facilities(id,name,time_zone) VALUES (\(facility),'Synthetic inventory','Asia/Tokyo')").collect() }
            for (i,user) in users.enumerated() {
                let handle = authRandomBytes()
                _ = try await pool.query("INSERT INTO public.users(id) VALUES (\(user))").collect()
                _ = try await pool.query("INSERT INTO public.passkey_accounts(user_id,user_handle) VALUES (\(user),\(handle))").collect()
                _ = try await pool.query("INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up) VALUES (\(credentials[i]),\(user),\(handle),\(Data([0])),0,false,false)").collect()
            }
            for (facility,user,role) in [(facilities[0],users[0],"manager"),(facilities[0],users[1],"staff"),(facilities[1],users[2],"owner")] {
                _ = try await pool.query("INSERT INTO public.facility_memberships(facility_id,user_id,role) VALUES (\(facility),\(user),\(role))").collect()
            }
            let kinds = ["private_sauna","shared_sauna","day_tent","overnight_tent"]
            for facility in facilities {
                for (i,kind) in kinds.enumerated() {
                    _ = try await pool.query("INSERT INTO public.products(facility_id,id,kind,name,currency,unit_price_minor) VALUES (\(facility),\(products[i]),\(kind),'Synthetic product','JPY',0)").collect()
                    let nights = i == 3 ? 1 : 0
                    _ = try await pool.query("INSERT INTO public.product_offerings(facility_id,product_id,kind,capacity,minimum_duration_minutes,maximum_duration_minutes,minimum_nights,maximum_nights) VALUES (\(facility),\(products[i]),\(kind),2,1,60,\(nights),\(nights))").collect()
                }
                for (i,kind) in ["sauna","tent"].enumerated() {
                    _ = try await pool.query("INSERT INTO public.inventory_resources(facility_id,id,kind,name,capacity,enabled) VALUES (\(facility),\(resources[i]),\(kind),'Synthetic resource',2,true)").collect()
                }
            }
            // The internal issuer is fixture setup, not a replacement for Passkey login.
            var grants: [SessionGrant] = []
            for (i,user) in users.enumerated() {
                grants.append(try await pool.withConnection { try await SessionStore.issue(on: $0,userID: user,credentialID: credentials[i],relyingParty: i == 3 ? .customer : .staff,ttlSeconds: 300) })
            }
            let fixture = InventoryFixture(pool: pool,facilities: facilities,users: users,credentials: credentials,grants: grants,products: products,resources: resources)
            for (facilityIndex,personIndex) in [(0,0),(1,2)] {
                for i in 0..<4 {
                    try await fixture.service(personIndex).linkProduct(facilityID: facilities[facilityIndex],resourceID: resources[i < 2 ? 0 : 1],productID: products[i],csrfToken: grants[personIndex].session.csrfToken)
                }
            }
            try await body(fixture)
            try await cleanup()
        } catch { try await cleanup(); throw error }
    }
}

private func inventoryReject<Value>(_ expected: InventoryError, _ operation: () async throws -> Value) async {
    do { _ = try await operation(); Issue.record("Expected inventory rejection") }
    catch { #expect(error as? InventoryError == expected) }
}

private actor InventoryPID {
    var value: Int?
    func set(_ value: Int) { self.value = value }
}

private func waitForInventoryLock(_ state: InventoryPID, pool: PostgresClient) async throws {
    for _ in 0..<200 {
        if let pid = await state.value {
            let rows = try await pool.query("SELECT count(*) FROM pg_stat_activity WHERE pid=\(pid)::integer AND wait_event_type='Lock'")
            for try await count in rows.decode(Int.self) { if count == 1 { return } }
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw InventoryError.unavailable
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL fixture database"))
struct InventoryStoreTests {
    @Test func configurationRequiresCurrentRoleAndPhysicalKind() async throws {
        try await withInventoryFixture { f in
            let created = try await f.service().createResource(facilityID: f.facilities[0],kind: .sauna,name: " New ",capacity: 3,csrfToken: f.csrf)
            #expect(created.name == "New" && !created.enabled && created.capacity == 3)
            let enabled = try await f.service().setResourceEnabled(facilityID: f.facilities[0],id: created.id,enabled: true,csrfToken: f.csrf)
            #expect(enabled.enabled)
            let visible = try await f.service(1).resource(facilityID: f.facilities[0],id: created.id)
            #expect(visible.id == created.id)
            await inventoryReject(.notAvailable) { try await f.service(1).setResourceEnabled(facilityID: f.facilities[0],id: created.id,enabled: false,csrfToken: f.grants[1].session.csrfToken) }
            await inventoryReject(.notAvailable) { try await f.service(2).resource(facilityID: f.facilities[0],id: created.id) }
            await inventoryReject(.invalidInput) { try await f.service().linkProduct(facilityID: f.facilities[0],resourceID: created.id,productID: f.products[2],csrfToken: f.csrf) }
            await inventoryReject(.invalidInput) { try await f.service().createResource(facilityID: f.facilities[0],kind: .tent,name: " ",capacity: 0,csrfToken: f.csrf) }
            do { _ = try await f.service(3).resource(facilityID: f.facilities[0],id: created.id); Issue.record("Customer must not use staff service") }
            catch { #expect(error as? AuthenticationError == .rejected) }
            do { _ = try await f.service().setResourceEnabled(facilityID: f.facilities[0],id: created.id,enabled: false,csrfToken: "invalid"); Issue.record("CSRF must be checked") }
            catch { #expect(error as? AuthenticationError == .rejected) }
        }
    }

    @Test func sharedCapacityWholeResourceAdjacencyAndReleaseAreCoherent() async throws {
        try await withInventoryFixture { f in
            let first = try await f.allocate(1,seats: .sharedSeat(0))
            let second = try await f.allocate(1,seats: .sharedSeat(1))
            #expect(first.seats == .sharedSeat(0) && second.seats == .sharedSeat(1))
            await inventoryReject(.notAvailable) { try await f.service(2).claim(facilityID: f.facilities[0],id: first.id) }
            await inventoryReject(.notAvailable) { try await f.service(2).release(facilityID: f.facilities[0],id: first.id,csrfToken: f.grants[2].session.csrfToken) }
            await inventoryReject(.notAvailable) { try await f.service().claim(facilityID: f.facilities[1],id: first.id) }
            await inventoryReject(.notAvailable) { try await f.service(1).release(facilityID: f.facilities[0],id: first.id,csrfToken: f.grants[1].session.csrfToken) }
            await inventoryReject(.notAvailable) { try await f.service(1).allocate(facilityID: f.facilities[0],resourceID: f.resources[0],productID: f.products[1],interval: f.interval(),seats: .sharedSeat(0),csrfToken: f.grants[1].session.csrfToken) }
            await inventoryReject(.conflict) { try await f.allocate(0,seats: .wholeResource) }
            await inventoryReject(.conflict) { try await f.allocate(1,seats: .sharedSeat(0)) }
            await inventoryReject(.invalidInput) { try await f.allocate(1,seats: .sharedSeat(2)) }
            await inventoryReject(.invalidInput) { try await f.allocate(0,seats: .sharedSeat(0)) }
            _ = try await f.allocate(0,seats: .wholeResource,offset: 3600)
            _ = try await f.allocate(2,seats: .wholeResource)
            await inventoryReject(.conflict) { try await f.allocate(3,seats: .wholeResource) }
            _ = try await f.service(2).allocate(facilityID: f.facilities[1],resourceID: f.resources[0],productID: f.products[0],interval: f.interval(),seats: .wholeResource,csrfToken: f.grants[2].session.csrfToken)
            _ = try await f.service().release(facilityID: f.facilities[0],id: first.id,csrfToken: f.csrf)
            await inventoryReject(.conflict) { try await f.allocate(0,seats: .wholeResource) }
            _ = try await f.service().release(facilityID: f.facilities[0],id: second.id,csrfToken: f.csrf)
            let whole = try await f.allocate(0,seats: .wholeResource)
            _ = try await f.service().setResourceEnabled(facilityID: f.facilities[0],id: f.resources[0],enabled: false,csrfToken: f.csrf)
            await inventoryReject(.notAvailable) { try await f.allocate(1,seats: .sharedSeat(0),offset: 7200) }
            let released = try await f.service().release(facilityID: f.facilities[0],id: whole.id,csrfToken: f.csrf)
            #expect(released.releasedAt != nil)
            await inventoryReject(.notAvailable) { try await f.service().release(facilityID: f.facilities[0],id: whole.id,csrfToken: f.csrf) }
        }
    }

    @Test func concurrentPrivateAndSharedRequestsNeverExceedPhysicalCapacity() async throws {
        try await withInventoryFixture { f in
            let winners = try await withThrowingTaskGroup(of: Int?.self) { tasks in
                for i in 0..<12 {
                    tasks.addTask {
                        let kind = i % 3 == 0 ? 0 : 1
                        do { _ = try await f.allocate(kind,seats: kind == 0 ? .wholeResource : .sharedSeat(i % 2)); return kind }
                        catch InventoryError.conflict { return nil }
                    }
                }
                var winners: [Int] = []
                for try await result in tasks { if let result { winners.append(result) } }
                return winners
            }
            #expect(winners == [0] || (winners.count == 2 && winners.allSatisfy { $0 == 1 }))
            let rows = try await f.pool.query("SELECT count(*) FROM public.inventory_claims WHERE facility_id=\(f.facilities[0]) AND released_at IS NULL")
            for try await count in rows.decode(Int.self) { #expect(count == winners.count) }
        }
    }

    @Test(arguments: ["session", "expiry", "credential", "membership", "role", "disabled"])
    func allocationRechecksStateAfterAnObservedResourceLockWait(change: String) async throws {
        try await withInventoryFixture { f in
            let state = InventoryPID()
            try await f.pool.withConnection { blocker in
                try await sql("BEGIN",blocker)
                do {
                    try await sql("SELECT id FROM public.inventory_resources WHERE facility_id=\(f.facilities[0]) AND id=\(f.resources[0]) FOR UPDATE",blocker)
                    async let rejected: Void = {
                        await inventoryReject(.notAvailable) {
                            try await SessionStore(client: f.pool,relyingParty: .staff).withSessionTransaction(token: f.grants[0].token) { connection,session in
                                let rows = try await connection.query("SELECT pg_backend_pid()",logger: inventoryLogger)
                                for try await pid in rows.decode(Int.self) { await state.set(pid) }
                                return try await InventoryStore(connection: connection,subject: session.subject,token: f.grants[0].token,party: .staff).allocate(facilityID: f.facilities[0],resourceID: f.resources[0],productID: f.products[1],interval: f.interval(),seats: .sharedSeat(0))
                            }
                        }
                    }()
                    try await waitForInventoryLock(state,pool: f.pool)
                    switch change {
                    case "session": _ = try await f.pool.query("UPDATE public.auth_sessions SET revoked_at=clock_timestamp() WHERE user_id=\(f.users[0])").collect()
                    case "expiry": _ = try await f.pool.query("UPDATE public.auth_sessions SET created_at=clock_timestamp()-interval '2 hours',expires_at=clock_timestamp()-interval '1 hour' WHERE user_id=\(f.users[0])").collect()
                    case "credential": _ = try await f.pool.query("UPDATE public.passkey_credentials SET revoked_at=clock_timestamp() WHERE user_id=\(f.users[0])").collect()
                    case "membership": _ = try await f.pool.query("UPDATE public.facility_memberships SET status='revoked' WHERE facility_id=\(f.facilities[0]) AND user_id=\(f.users[0])").collect()
                    case "role": _ = try await f.pool.query("UPDATE public.facility_memberships SET role='staff' WHERE facility_id=\(f.facilities[0]) AND user_id=\(f.users[0])").collect()
                    default: try await sql("UPDATE public.inventory_resources SET enabled=false WHERE facility_id=\(f.facilities[0]) AND id=\(f.resources[0])",blocker)
                    }
                    try await sql("COMMIT",blocker)
                    await rejected
                } catch { try await sql("ROLLBACK",blocker); throw error }
            }
            let rows = try await f.pool.query("SELECT count(*) FROM public.inventory_claims WHERE facility_id=\(f.facilities[0])")
            for try await count in rows.decode(Int.self) { #expect(count == 0) }
        }
    }

    @Test func exclusionWaitsForAConcurrentTransactionAndRejectsItsOverlap() async throws {
        try await withInventoryFixture { f in
            let state = InventoryPID()
            let interval = try f.interval()
            try await f.pool.withConnection { winner in
                try await sql("BEGIN",winner)
                do {
                    try await sql("INSERT INTO public.inventory_claims(facility_id,product_id,product_kind,resource_id,resource_capacity,starts_at,ends_at,seat_slots) VALUES (\(f.facilities[0]),\(f.products[0]),'private_sauna',\(f.resources[0]),2,\(interval.startsAt),\(interval.endsAt),int4range(NULL,NULL,'()'))",winner)
                    async let loser: Void = f.pool.withConnection { connection in
                        let pids = try await connection.query("SELECT pg_backend_pid()",logger: inventoryLogger)
                        for try await pid in pids.decode(Int.self) { await state.set(pid) }
                        do {
                            try await sql("INSERT INTO public.inventory_claims(facility_id,product_id,product_kind,resource_id,resource_capacity,starts_at,ends_at,seat_slots) VALUES (\(f.facilities[0]),\(f.products[1]),'shared_sauna',\(f.resources[0]),2,\(interval.startsAt),\(interval.endsAt),int4range(0,1,'[)'))",connection)
                            Issue.record("Database exclusion must reject a committed overlap")
                        } catch {
                            #expect((error as? PSQLError)?.serverInfo?[.sqlState] == "23P01")
                            #expect((error as? PSQLError)?.serverInfo?[.constraintName] == "inventory_claim_no_overlap")
                        }
                    }
                    try await waitForInventoryLock(state,pool: f.pool)
                    try await sql("COMMIT",winner)
                    try await loser
                } catch { try await sql("ROLLBACK",winner); throw error }
            }
            let rows = try await f.pool.query("SELECT count(*) FROM public.inventory_claims WHERE facility_id=\(f.facilities[0])")
            for try await count in rows.decode(Int.self) { #expect(count == 1) }
        }
    }

    @Test(arguments: [false,true])
    func deadlineWhileWaitingCannotCommitAnAllocationOrRelease(releasing: Bool) async throws {
        try await withInventoryFixture { f in
            let existing = releasing ? try await f.allocate(1,seats: .sharedSeat(0)) : nil
            let state = InventoryPID()
            try await f.pool.withConnection { blocker in
                try await sql("BEGIN",blocker)
                do {
                    try await sql("SELECT id FROM public.inventory_resources WHERE facility_id=\(f.facilities[0]) AND id=\(f.resources[0]) FOR UPDATE",blocker)
                    async let timedOut: Void = {
                        do {
                            _ = try await SessionStore(client: f.pool,relyingParty: .staff).withSessionTransaction(token: f.grants[0].token) { connection,session in
                                let rows = try await connection.query("SELECT pg_backend_pid()",logger: inventoryLogger)
                                for try await pid in rows.decode(Int.self) { await state.set(pid) }
                                let store = InventoryStore(connection: connection,subject: session.subject,token: f.grants[0].token,party: .staff)
                                if let existing { return try await store.release(facilityID: f.facilities[0],id: existing.id) }
                                return try await store.allocate(facilityID: f.facilities[0],resourceID: f.resources[0],productID: f.products[1],interval: f.interval(),seats: .sharedSeat(0))
                            }
                            Issue.record("Blocked transaction must reach its deadline")
                        } catch {
                            #expect(error is CancellationError || error as? AuthenticationError == .unavailable)
                        }
                    }()
                    try await waitForInventoryLock(state,pool: f.pool)
                    await timedOut
                    try await sql("ROLLBACK",blocker)
                } catch { try await sql("ROLLBACK",blocker); throw error }
            }
            let rows = try await f.pool.query("SELECT count(*) FROM public.inventory_claims WHERE facility_id=\(f.facilities[0]) AND released_at IS NULL")
            for try await count in rows.decode(Int.self) { #expect(count == (releasing ? 1 : 0)) }
            let total = try await f.pool.query("SELECT count(*) FROM public.inventory_claims WHERE facility_id=\(f.facilities[0])")
            for try await count in total.decode(Int.self) { #expect(count == (releasing ? 1 : 0)) }
            if let existing {
                let persisted = try await f.service().claim(facilityID: f.facilities[0],id: existing.id)
                #expect(persisted.releasedAt == nil)
            }
            let resource = try await f.service().resource(facilityID: f.facilities[0],id: f.resources[0])
            #expect(resource.enabled)
        }
    }
}
