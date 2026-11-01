public import Foundation
import Logging
public import PostgresNIO
public import SaunaAPIIdentity

public enum FacilityStoreError: Error, Equatable, CustomStringConvertible {
    /// Deliberately does not distinguish missing resources from denied access.
    case notAvailable
    case invalidInput
    case unavailable

    public var description: String {
        switch self {
        case .notAvailable: "The requested resource is not available."
        case .invalidInput: "The product input is invalid."
        case .unavailable: "The product service is unavailable."
        }
    }
}

/// A small internal staff catalog projection, not a public API response.
public struct FacilityProduct: Sendable, Equatable {
    public let id: UUID
    public let name: String
}

/// Facility-scoped database access. Every operation rechecks active membership
/// and the relevant role in the same SQL statement as the data access.
///
/// READ COMMITTED semantics apply: a revocation committed before the next
/// statement is visible; this is not global serialization with concurrent
/// revocations. Workspace employment verification and public HTTP endpoints are
/// separate requirements and are not enabled by this database-layer foundation.
public struct FacilityStore: Sendable {
    private enum Executor: Sendable {
        case client(PostgresClient)
        case connection(PostgresConnection)
    }

    private let executor: Executor
    private let subject: VerifiedSubject
    private let facilityID: UUID
    private let sessionHash: Data?
    private let sessionOrigin: String?

    public init(client: PostgresClient, subject: VerifiedSubject, facilityID: UUID) {
        self.executor = .client(client)
        self.subject = subject
        self.facilityID = facilityID
        self.sessionHash = nil
        self.sessionOrigin = nil
    }

    // Database-layer fixture tests use this unbound transaction executor; HTTP
    // cannot use it because FacilityService requires the session-bound overload.
    init(connection: PostgresConnection, subject: VerifiedSubject, facilityID: UUID) {
        self.executor = .connection(connection)
        self.subject = subject
        self.facilityID = facilityID
        self.sessionHash = nil
        self.sessionOrigin = nil
    }

    init(connection: PostgresConnection, subject: VerifiedSubject, facilityID: UUID,
         sessionToken: AuthSessionToken, relyingParty: LocalPasskeyRelyingParty) {
        self.executor = .connection(connection)
        self.subject = subject
        self.facilityID = facilityID
        self.sessionHash = sessionToken.digest
        self.sessionOrigin = relyingParty.origin
    }

    public func listProducts(limit: Int = 100) async throws -> [FacilityProduct] {
        guard (1...100).contains(limit) else { throw FacilityStoreError.invalidInput }
        do {
            // The membership-side row remains for an authorized empty catalog;
            // zero rows mean denied access rather than a successful empty list.
            let rows = try await query("""
                SELECT p.id, p.name
                FROM public.facility_memberships AS m
                LEFT JOIN public.products AS p ON p.facility_id = m.facility_id
                WHERE m.facility_id = \(facilityID) AND m.user_id = \(subject.userID)
                  AND m.status = 'active' AND m.role IN ('owner', 'manager', 'staff')
                  AND (\(sessionHash == nil) OR EXISTS (
                    SELECT 1 FROM public.auth_sessions AS s
                    JOIN public.passkey_credentials AS c ON c.id=s.credential_id AND c.user_id=s.user_id
                    WHERE s.token_hash=\(sessionHash) AND s.origin=\(sessionOrigin)
                      AND s.user_id=\(subject.userID) AND s.revoked_at IS NULL
                      AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp()
                      AND c.revoked_at IS NULL
                  ))
                ORDER BY p.id LIMIT \(limit)
                """)
            var authorized = false
            var products: [FacilityProduct] = []
            for try await (id, name) in rows.decode((UUID?, String?).self) {
                authorized = true
                if let id, let name { products.append(.init(id: id, name: name)) }
            }
            guard authorized else { throw FacilityStoreError.notAvailable }
            return products
        } catch { throw mapped(error) }
    }

    public func product(id: UUID) async throws -> FacilityProduct {
        do {
            let rows = try await query("""
                SELECT p.id, p.name FROM public.products AS p
                WHERE p.facility_id = \(facilityID) AND p.id = \(id)
                  AND EXISTS (
                    SELECT 1 FROM public.facility_memberships AS m
                    WHERE m.facility_id = p.facility_id AND m.user_id = \(subject.userID)
                      AND m.status = 'active' AND m.role IN ('owner', 'manager', 'staff')
                  )
                  AND (\(sessionHash == nil) OR EXISTS (
                    SELECT 1 FROM public.auth_sessions AS s
                    JOIN public.passkey_credentials AS c ON c.id=s.credential_id AND c.user_id=s.user_id
                    WHERE s.token_hash=\(sessionHash) AND s.origin=\(sessionOrigin)
                      AND s.user_id=\(subject.userID) AND s.revoked_at IS NULL
                      AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp()
                      AND c.revoked_at IS NULL
                  ))
                """)
            for try await (id, name) in rows.decode((UUID, String).self) {
                return .init(id: id, name: name)
            }
            throw FacilityStoreError.notAvailable
        } catch { throw mapped(error) }
    }

    public func renameProduct(id: UUID, name: String) async throws -> FacilityProduct {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 200, !name.contains("\0") else {
            throw FacilityStoreError.invalidInput
        }
        do {
            let rows = try await query("""
                UPDATE public.products AS p SET name = \(name)
                WHERE p.facility_id = \(facilityID) AND p.id = \(id)
                  AND EXISTS (
                    SELECT 1 FROM public.facility_memberships AS m
                    WHERE m.facility_id = p.facility_id AND m.user_id = \(subject.userID)
                      AND m.status = 'active' AND m.role IN ('owner', 'manager')
                  )
                  AND (\(sessionHash == nil) OR EXISTS (
                    SELECT 1 FROM public.auth_sessions AS s
                    JOIN public.passkey_credentials AS c ON c.id=s.credential_id AND c.user_id=s.user_id
                    WHERE s.token_hash=\(sessionHash) AND s.origin=\(sessionOrigin)
                      AND s.user_id=\(subject.userID) AND s.revoked_at IS NULL
                      AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp()
                      AND c.revoked_at IS NULL
                  ))
                RETURNING p.id, p.name
                """)
            for try await (id, name) in rows.decode((UUID, String).self) {
                return .init(id: id, name: name)
            }
            throw FacilityStoreError.notAvailable
        } catch { throw mapped(error) }
    }

    private func query(_ query: PostgresQuery) async throws -> PostgresRowSequence {
        switch executor {
        case .client(let client): return try await client.query(query)
        case .connection(let connection):
            let logger = Logger(label: "SaunaFacilityStore") { _ in SwiftLogNoOpLogHandler() }
            return try await connection.query(query, logger: logger)
        }
    }

    private func mapped(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? FacilityStoreError { return error }
        // Never stringify a raw driver error, SQL or query bindings.
        return FacilityStoreError.unavailable
    }
}
