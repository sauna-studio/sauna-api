import Foundation
import HTTPTypes
import HummingbirdTesting
import PostgresNIO
import SaunaAPIDatabase
@testable import SaunaAPIServer
import Testing

@Suite(.serialized)
struct WorkspaceEmploymentSchedulerTests {
    private enum EndPolling: Error { case finished }

    @Test func pollingContinuesAfterClaimFailureAndEmptyQueue() async {
        actor Queue {
            var attempts = 0
            func claim() throws -> WorkspaceEmploymentClaim? {
                attempts += 1
                if attempts == 1 { throw EndPolling.finished }
                return nil
            }
        }
        let queue = Queue()
        let scheduler = WorkspaceEmploymentScheduler(
            claim: { try await queue.claim() },
            verify: { _ in Issue.record("No enrollment was claimed"); return .unavailable },
            finish: { _, _ in Issue.record("No outcome should be written") },
            sleep: { _ in
                if await queue.attempts == 2 { throw EndPolling.finished }
            }
        )
        await #expect(throws: EndPolling.finished) { try await scheduler.run() }
        #expect(await queue.attempts == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
    func periodicWorkerRevokesOnlyTheEnrolledFacilityAndRecordsOneAudit() async throws {
        try await withFacilityHTTPFixture { fixture in
            let pool = fixture.pool
            let facility = fixture.facilityA
            let user = fixture.managerID
            _ = try await pool.query("""
                INSERT INTO public.workspace_employment_rechecks
                    (facility_id, user_id, directory_user_id, customer_id, group_id)
                VALUES (\(facility), \(user), 'fixture-user', 'fixture-tenant', 'fixture-group')
                """).collect()
            let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: pool))
            try await app.test(.live) { http in
                let headers = fixture.headers(fixture.manager)
                try await http.execute(uri: fixture.pathA, method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                }
                let store = WorkspaceEmploymentStore(client: pool)
                let scheduler = WorkspaceEmploymentScheduler(
                    claim: { try await store.claimNextDue(leaseSeconds: 60) },
                    verify: { snapshot in
                        #expect(snapshot.facilityID == facility)
                        #expect(snapshot.userID == user)
                        #expect(snapshot.directoryUserID == "fixture-user")
                        #expect(snapshot.customerID == "fixture-tenant")
                        #expect(snapshot.groupID == "fixture-group")
                        return .ineligible
                    },
                    finish: { snapshot, outcome in
                        let applied = try await store.finish(snapshot, outcome: outcome, retryAfterSeconds: 300)
                        #expect(applied)
                    },
                    sleep: { delay in
                        #expect(delay == .seconds(5))
                        throw EndPolling.finished
                    }
                )
                await #expect(throws: EndPolling.finished) { try await scheduler.run() }
                try await http.execute(uri: fixture.pathA, method: .get, headers: headers) { response in
                    #expect(response.status == .notFound)
                }
                let other = "/staff/facilities/\(fixture.emptyFacility)/products"
                try await http.execute(uri: other, method: .get, headers: headers) { response in
                    #expect(response.status == .ok)
                }
                let audit = try await pool.query("""
                    SELECT count(*)::int FROM public.workspace_employment_revocation_audit
                    WHERE facility_id = \(facility) AND user_id = \(user)
                    """)
                var counts: [Int] = []
                for try await count in audit.decode(Int.self) { counts.append(count) }
                #expect(counts == [1])
                _ = try await pool.query("""
                    DELETE FROM public.workspace_employment_revocation_audit
                    WHERE facility_id = \(facility) AND user_id = \(user)
                    """).collect()
            }
        }
    }
}
