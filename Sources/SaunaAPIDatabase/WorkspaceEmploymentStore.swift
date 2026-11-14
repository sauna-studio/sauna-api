package import Foundation
package import PostgresNIO

package struct WorkspaceEmploymentClaim: Sendable {
    package let facilityID: UUID
    package let userID: UUID
    package let directoryUserID: String
    package let customerID: String
    package let groupID: String
    fileprivate let token: UUID
    fileprivate let membershipVersion: String
    fileprivate let enrollmentVersion: String

    package init(facilityID: UUID, userID: UUID, directoryUserID: String, customerID: String, groupID: String,
                 token: UUID, membershipVersion: String, enrollmentVersion: String) {
        self.facilityID = facilityID
        self.userID = userID
        self.directoryUserID = directoryUserID
        self.customerID = customerID
        self.groupID = groupID
        self.token = token
        self.membershipVersion = membershipVersion
        self.enrollmentVersion = enrollmentVersion
    }
}

package enum WorkspaceEmploymentOutcome: Sendable, Equatable {
    case eligible
    case unavailable
    case ineligible
}

package enum WorkspaceEmploymentClaimScope: Sendable, Equatable {
    case all
    case synthetic
}

package enum WorkspaceEmploymentStoreError: Error {
    case invalidInterval
    case unavailable
}

package struct WorkspaceEmploymentStore: Sendable {
    private let client: PostgresClient

    package init(client: PostgresClient) {
        self.client = client
    }

    package func claimNextDue(leaseSeconds: Int, scope: WorkspaceEmploymentClaimScope = .all) async throws -> WorkspaceEmploymentClaim? {
        guard (1...3_600).contains(leaseSeconds) else { throw WorkspaceEmploymentStoreError.invalidInterval }
        do {
            let rows = try await client.query("""
                WITH due AS MATERIALIZED (
                    SELECT e.facility_id, e.user_id, m.xmin::text AS membership_version
                    FROM public.workspace_employment_rechecks e
                    JOIN public.facility_memberships m USING (facility_id, user_id)
                    WHERE m.status = 'active' AND e.next_check_at <= clock_timestamp()
                      AND (e.claimed_until IS NULL OR e.claimed_until <= clock_timestamp())
                      AND (\(scope == .all) OR (
                          e.directory_user_id COLLATE "C" = 'fixture-sauna-employment-user'
                          AND e.customer_id COLLATE "C" = 'fixture-sauna-employment-tenant'
                          AND e.group_id COLLATE "C" = 'fixture-sauna-employment-group'
                      ))
                    ORDER BY e.next_check_at, e.facility_id, e.user_id
                    LIMIT 1
                    FOR UPDATE OF e, m SKIP LOCKED
                )
                UPDATE public.workspace_employment_rechecks e
                SET claim_token = gen_random_uuid(),
                    claimed_until = clock_timestamp() + make_interval(secs => \(leaseSeconds)::double precision)
                FROM due
                WHERE e.facility_id = due.facility_id AND e.user_id = due.user_id
                RETURNING e.facility_id, e.user_id, e.directory_user_id, e.customer_id, e.group_id,
                          e.claim_token, due.membership_version, e.xmin::text
                """)
            var claim: WorkspaceEmploymentClaim?
            for try await (facility, user, directory, customer, group, token, membershipVersion, enrollmentVersion) in rows.decode(
                (UUID, UUID, String, String, String, UUID, String, String).self
            ) {
                claim = .init(facilityID: facility, userID: user, directoryUserID: directory, customerID: customer,
                              groupID: group, token: token, membershipVersion: membershipVersion, enrollmentVersion: enrollmentVersion)
            }
            return claim
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WorkspaceEmploymentStoreError.unavailable
        }
    }

    // Row versions detect writes by membership managers and re-enrollment even when values are restored.
    // They supplement the UUID claim for the short lease; they are unsuitable as durable revisions.
    /// A locked, expired, or superseded claim is skipped. A failure after dispatch leaves the outcome unknown.
    /// Repeating a completed claim cannot repeat its audit.
    package func finish(_ claim: WorkspaceEmploymentClaim, outcome: WorkspaceEmploymentOutcome,
                        retryAfterSeconds: Int) async throws -> Bool {
        guard (1...86_400).contains(retryAfterSeconds) else { throw WorkspaceEmploymentStoreError.invalidInterval }
        let shouldRevoke = outcome == .ineligible
        do {
            let rows = try await client.query("""
                WITH locked AS MATERIALIZED (
                    SELECT e.facility_id, e.user_id, e.claimed_until
                    FROM public.workspace_employment_rechecks e
                    JOIN public.facility_memberships m USING (facility_id, user_id)
                    WHERE e.facility_id = \(claim.facilityID) AND e.user_id = \(claim.userID)
                      AND e.xmin::text = \(claim.enrollmentVersion)
                      AND e.claim_token = \(claim.token)
                      AND e.directory_user_id = \(claim.directoryUserID)
                      AND e.customer_id = \(claim.customerID) AND e.group_id = \(claim.groupID)
                      AND m.status = 'active' AND m.xmin::text = \(claim.membershipVersion)
                    FOR UPDATE OF e, m SKIP LOCKED
                ),
                current_claim AS MATERIALIZED (
                    SELECT facility_id, user_id FROM locked WHERE claimed_until > clock_timestamp()
                ),
                revoked AS (
                    UPDATE public.facility_memberships m SET status = 'revoked'
                    FROM current_claim c
                    WHERE m.facility_id = c.facility_id AND m.user_id = c.user_id AND \(shouldRevoke)
                    RETURNING m.facility_id, m.user_id
                ),
                audited AS (
                    INSERT INTO public.workspace_employment_revocation_audit (claim_token, facility_id, user_id)
                    SELECT \(claim.token), facility_id, user_id FROM revoked
                )
                UPDATE public.workspace_employment_rechecks e
                SET claim_token = NULL, claimed_until = NULL,
                    next_check_at = clock_timestamp() + make_interval(secs => \(retryAfterSeconds)::double precision)
                FROM current_claim c
                WHERE e.facility_id = c.facility_id AND e.user_id = c.user_id
                RETURNING 1
                """)
            return try await !rows.collect().isEmpty
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WorkspaceEmploymentStoreError.unavailable
        }
    }
}
