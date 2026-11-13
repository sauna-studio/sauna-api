import Foundation
import Logging
import PostgresNIO
import Testing
@testable import SaunaAPIDatabase

extension WorkspaceEmploymentSchedulerTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL fixture database")) func confirmedIneligibilityRevokesOnlyEnrolledMembershipAndAuditsOnce() async throws {
        try await withEmploymentFixture { fixture in
            let results = try await withThrowingTaskGroup(of: WorkspaceEmploymentClaim?.self) { group in
                for _ in 0..<2 {
                    group.addTask { try await fixture.store.claimNextDue(leaseSeconds: 60) }
                }
                var claims: [WorkspaceEmploymentClaim] = []
                for try await result in group {
                    if let result { claims.append(result) }
                }
                return claims
            }
            try #require(results.count == 1)
            let claim = try #require(results.first)
            #expect(claim.facilityID == fixture.facility)
            #expect(try await fixture.store.finish(claim, outcome: .ineligible, retryAfterSeconds: 10))
            #expect(try await !fixture.store.finish(claim, outcome: .ineligible, retryAfterSeconds: 10))
            #expect(try await fixture.status(in: fixture.facility) == "revoked")
            #expect(try await fixture.status(in: fixture.otherFacility) == "active")
            #expect(try await fixture.auditCount() == 1)
            #expect(try await fixture.store.claimNextDue(leaseSeconds: 60) == nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL fixture database"), arguments: [WorkspaceEmploymentOutcome.eligible, .unavailable])
    func nonnegativeOutcomesRescheduleWithoutChangingAccess(outcome: WorkspaceEmploymentOutcome) async throws {
        try await withEmploymentFixture { fixture in
            let claim = try #require(try await fixture.store.claimNextDue(leaseSeconds: 60))
            #expect(try await fixture.store.finish(claim, outcome: outcome, retryAfterSeconds: 30))
            #expect(try await fixture.store.claimNextDue(leaseSeconds: 60) == nil)
            #expect(try await fixture.status(in: fixture.facility) == "active")
            #expect(try await fixture.auditCount() == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL fixture database"), arguments: ["membership", "binding", "expiry"])
    func staleClaimCannotRevokeAfterStateChanges(change: String) async throws {
        try await withEmploymentFixture { fixture in
            let claim = try #require(try await fixture.store.claimNextDue(leaseSeconds: change == "expiry" ? 1 : 60))
            switch change {
            case "membership":
                try await fixture.execute("""
                    UPDATE public.facility_memberships SET role='owner' WHERE facility_id=\(fixture.facility) AND user_id=\(fixture.user)
                    """)
                try await fixture.execute("""
                    UPDATE public.facility_memberships SET role='manager' WHERE facility_id=\(fixture.facility) AND user_id=\(fixture.user)
                    """)
            case "binding":
                try await fixture.execute("""
                    UPDATE public.workspace_employment_rechecks SET group_id='different-group' WHERE facility_id=\(fixture.facility)
                    """)
                try await fixture.execute("""
                    UPDATE public.workspace_employment_rechecks SET group_id='employee-group' WHERE facility_id=\(fixture.facility)
                    """)
            default:
                try await fixture.execute("SELECT pg_sleep(1)")
            }
            #expect(try await !fixture.store.finish(claim, outcome: .ineligible, retryAfterSeconds: 10))
            #expect(try await fixture.status(in: fixture.facility) == "active")
            #expect(try await fixture.auditCount() == 0)
            if change == "expiry" {
                let fresh = try #require(try await fixture.store.claimNextDue(leaseSeconds: 60))
                #expect(try await fixture.store.finish(fresh, outcome: .ineligible, retryAfterSeconds: 10))
                #expect(try await fixture.auditCount() == 1)
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL fixture database"))
    func lockedMembershipDoesNotStallTheWorker() async throws {
        try await withEmploymentFixture { fixture in
            let claim = try #require(try await fixture.store.claimNextDue(leaseSeconds: 60))
            let logger = Logger(label: "EmploymentFixtures") { _ in SwiftLogNoOpLogHandler() }
            try await fixture.pool.withConnection { connection in
                _ = try await connection.query("BEGIN", logger: logger).collect()
                do {
                    _ = try await connection.query("""
                        SELECT 1 FROM public.facility_memberships
                        WHERE facility_id=\(fixture.facility) AND user_id=\(fixture.user) FOR UPDATE
                        """, logger: logger).collect()
                    #expect(try await !fixture.store.finish(claim, outcome: .ineligible, retryAfterSeconds: 10))
                } catch {
                    _ = try? await connection.query("ROLLBACK", logger: logger).collect()
                    throw error
                }
                _ = try await connection.query("ROLLBACK", logger: logger).collect()
            }
            #expect(try await fixture.status(in: fixture.facility) == "active")
            #expect(try await fixture.auditCount() == 0)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires isolated PostgreSQL fixture database")) func failedAuditInsertRollsBackRevocation() async throws {
        try await withEmploymentFixture { fixture in
            let claim = try #require(try await fixture.store.claimNextDue(leaseSeconds: 60))
            try await fixture.execute("""
                INSERT INTO public.workspace_employment_revocation_audit(claim_token, facility_id, user_id)
                SELECT claim_token, facility_id, user_id FROM public.workspace_employment_rechecks
                WHERE facility_id=\(fixture.facility) AND user_id=\(fixture.user)
                """)
            await #expect(throws: WorkspaceEmploymentStoreError.self) {
                try await fixture.store.finish(claim, outcome: .ineligible, retryAfterSeconds: 10)
            }
            #expect(try await fixture.status(in: fixture.facility) == "active")
            #expect(try await fixture.auditCount() == 1)
        }
    }
}

private struct EmploymentFixture: Sendable {
    let pool: PostgresClient
    let facility = UUID()
    let otherFacility = UUID()
    let user = UUID()
    var store: WorkspaceEmploymentStore { .init(client: pool) }

    func execute(_ query: PostgresQuery) async throws {
        _ = try await pool.query(query).collect()
    }

    func status(in facilityID: UUID) async throws -> String {
        let rows = try await pool.query("""
            SELECT status FROM public.facility_memberships WHERE facility_id=\(facilityID) AND user_id=\(user)
            """)
        for try await value in rows.decode(String.self) { return value }
        throw WorkspaceEmploymentStoreError.unavailable
    }

    func auditCount() async throws -> Int {
        let rows = try await pool.query("""
            SELECT count(*)::int FROM public.workspace_employment_revocation_audit WHERE facility_id=\(facility) AND user_id=\(user)
            """)
        for try await value in rows.decode(Int.self) { return value }
        throw WorkspaceEmploymentStoreError.unavailable
    }

    func setup() async throws {
        try await execute("INSERT INTO public.facilities(id,name,time_zone) VALUES (\(facility),'Employment','UTC'), (\(otherFacility),'Unaffected','UTC')")
        try await execute("INSERT INTO public.users(id) VALUES (\(user))")
        try await execute("""
            INSERT INTO public.facility_memberships(facility_id,user_id,role)
            VALUES (\(facility),\(user),'manager'), (\(otherFacility),\(user),'manager')
            """)
        try await execute("""
            INSERT INTO public.workspace_employment_rechecks(facility_id,user_id,directory_user_id,customer_id,group_id)
            VALUES (\(facility),\(user),'directory-id','customer-id','employee-group')
            """)
    }

    func cleanup() async throws {
        try await execute("DELETE FROM public.workspace_employment_revocation_audit WHERE facility_id=\(facility) AND user_id=\(user)")
        try await execute("DELETE FROM public.facility_memberships WHERE user_id=\(user)")
        try await execute("DELETE FROM public.users WHERE id=\(user)")
        try await execute("DELETE FROM public.facilities WHERE id IN (\(facility),\(otherFacility))")
    }
}

private func withEmploymentFixture(_ body: @escaping @Sendable (EmploymentFixture) async throws -> Void) async throws {
    let configuration = try LocalDatabaseConfiguration(environment: ProcessInfo.processInfo.environment)
    try await LocalDatabase.withClient(configuration: configuration, timeout: .seconds(30)) { pool in
        let fixture = EmploymentFixture(pool: pool)
        do {
            try await fixture.setup()
            try await body(fixture)
        } catch {
            try await fixture.cleanup()
            throw error
        }
        try await fixture.cleanup()
    }
}
