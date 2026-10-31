import Foundation
import Logging
import PostgresNIO
import SaunaAPIIdentity

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

    public init(client: PostgresClient, subject: VerifiedSubject, facilityID: UUID) {
        self.executor = .client(client)
        self.subject = subject
        self.facilityID = facilityID
    }

    // Only the module's tests inject a transaction-pinned connection. It is not a
    // public factory that can let a borrowed pool connection escape its lifetime.
    init(connection: PostgresConnection, subject: VerifiedSubject, facilityID: UUID) {
        self.executor = .connection(connection)
        self.subject = subject
        self.facilityID = facilityID
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
