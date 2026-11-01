import Foundation
import Logging
import PostgresNIO
import SaunaAPIIdentity

struct InventoryStore: Sendable {
    private let connection: PostgresConnection
    private let subjectID: UUID
    private let sessionHash: Data
    private let origin: String

    init(connection: PostgresConnection, subject: VerifiedSubject, token: AuthSessionToken, party: LocalPasskeyRelyingParty) {
        self.connection = connection
        subjectID = subject.userID
        sessionHash = token.digest
        origin = party.origin
    }

    func createResource(facilityID: UUID, id: UUID, kind: InventoryResourceKind, name: String, capacity: Int) async throws -> InventoryResource {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 200, !name.contains("\0"), (1...Int(Int32.max)).contains(capacity) else {
            throw InventoryError.invalidInput
        }
        let rows = try await query("""
            INSERT INTO public.inventory_resources(facility_id,id,kind,name,capacity)
            SELECT \(facilityID),\(id),\(kind.rawValue),\(name),\(capacity)
            FROM public.facility_memberships AS m
            WHERE m.facility_id=\(facilityID) AND m.user_id=\(subjectID)
              AND m.status='active' AND m.role IN ('owner','manager')
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            RETURNING facility_id,id,kind,name,capacity,enabled
            """)
        return try await resourceRow(rows)
    }

    func resource(facilityID: UUID, id: UUID) async throws -> InventoryResource {
        let rows = try await query("""
            SELECT r.facility_id,r.id,r.kind,r.name,r.capacity,r.enabled FROM public.inventory_resources AS r
            WHERE r.facility_id=\(facilityID) AND r.id=\(id)
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=r.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager','staff'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            """)
        return try await resourceRow(rows)
    }

    private func lockResource(facilityID: UUID, id: UUID, requireEnabled: Bool) async throws -> InventoryResource {
        let rows = try await query("""
            SELECT r.facility_id,r.id,r.kind,r.name,r.capacity,r.enabled FROM public.inventory_resources AS r
            WHERE r.facility_id=\(facilityID) AND r.id=\(id) AND (NOT \(requireEnabled) OR r.enabled)
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=r.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            FOR UPDATE OF r
            """)
        return try await resourceRow(rows)
    }

    func setEnabled(facilityID: UUID, id: UUID, enabled: Bool) async throws -> InventoryResource {
        _ = try await lockResource(facilityID: facilityID, id: id, requireEnabled: false)
        // A lock predicate evaluated before waiting is not fresh authorization.
        // This new statement rechecks the session/member after the lock is held.
        let rows = try await query("""
            UPDATE public.inventory_resources AS r SET enabled=\(enabled)
            WHERE r.facility_id=\(facilityID) AND r.id=\(id)
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=r.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            RETURNING r.facility_id,r.id,r.kind,r.name,r.capacity,r.enabled
            """)
        return try await resourceRow(rows)
    }

    func linkProduct(facilityID: UUID, resourceID: UUID, productID: UUID) async throws {
        _ = try await lockResource(facilityID: facilityID, id: resourceID, requireEnabled: false)
        let rows = try await query("""
            INSERT INTO public.inventory_product_resources(facility_id,product_id,product_kind,resource_id,resource_kind)
            SELECT r.facility_id,p.product_id,p.kind,r.id,r.kind
            FROM public.inventory_resources AS r JOIN public.product_offerings AS p ON p.facility_id=r.facility_id
            WHERE r.facility_id=\(facilityID) AND r.id=\(resourceID) AND p.product_id=\(productID)
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=r.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            RETURNING product_id
            """)
        for try await _ in rows.decode(UUID.self) { return }
        throw InventoryError.notAvailable
    }

    func allocate(facilityID: UUID, resourceID: UUID, productID: UUID, interval: InventoryInterval, seats: InventorySeats) async throws -> InventoryClaim {
        let resource = try await lockResource(facilityID: facilityID, id: resourceID, requireEnabled: true)
        let slot: Int?
        switch seats {
        case .wholeResource: slot = nil
        case .sharedSeat(let value):
            guard value >= 0, value < resource.capacity else { throw InventoryError.invalidInput }
            slot = value
        }
        let rows = try await query("""
            INSERT INTO public.inventory_claims(facility_id,product_id,product_kind,resource_id,resource_capacity,starts_at,ends_at,seat_slots)
            SELECT r.facility_id,p.product_id,p.product_kind,r.id,r.capacity,\(interval.startsAt),\(interval.endsAt),
                CASE WHEN \(slot)::integer IS NULL THEN int4range(NULL,NULL,'()')
                     ELSE int4range(\(slot)::integer,\(slot.map { $0 + 1 })::integer,'[)') END
            FROM public.inventory_resources AS r JOIN public.inventory_product_resources AS p
              ON p.facility_id=r.facility_id AND p.resource_id=r.id AND p.resource_kind=r.kind
            WHERE r.facility_id=\(facilityID) AND r.id=\(resourceID) AND p.product_id=\(productID) AND r.enabled
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=r.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            RETURNING facility_id,id,product_id,product_kind,resource_id,resource_capacity,starts_at,ends_at,
                      lower(seat_slots),upper(seat_slots),released_at
            """)
        return try await claimRow(rows)
    }

    func claim(facilityID: UUID, id: UUID) async throws -> InventoryClaim {
        let rows = try await query("""
            SELECT c.facility_id,c.id,c.product_id,c.product_kind,c.resource_id,c.resource_capacity,c.starts_at,c.ends_at,
                   lower(c.seat_slots),upper(c.seat_slots),c.released_at FROM public.inventory_claims AS c
            WHERE c.facility_id=\(facilityID) AND c.id=\(id)
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=c.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager','staff'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS key
                ON key.id=s.credential_id AND key.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND key.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            """)
        return try await claimRow(rows)
    }

    func release(facilityID: UUID, id: UUID) async throws -> InventoryClaim {
        // A scoped read finds the lock target; it never substitutes for the
        // mutation's fresh session/member check after acquiring that resource.
        let existing = try await claim(facilityID: facilityID, id: id)
        _ = try await lockResource(facilityID: facilityID, id: existing.resourceID, requireEnabled: false)
        let rows = try await query("""
            UPDATE public.inventory_claims AS c SET released_at=clock_timestamp()
            WHERE c.facility_id=\(facilityID) AND c.id=\(id) AND c.resource_id=\(existing.resourceID)
              AND c.released_at IS NULL
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m WHERE m.facility_id=c.facility_id
                AND m.user_id=\(subjectID) AND m.status='active' AND m.role IN ('owner','manager'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS key
                ON key.id=s.credential_id AND key.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND key.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            RETURNING c.facility_id,c.id,c.product_id,c.product_kind,c.resource_id,c.resource_capacity,c.starts_at,c.ends_at,
                      lower(c.seat_slots),upper(c.seat_slots),c.released_at
            """)
        return try await claimRow(rows)
    }

    private func resourceRow(_ rows: PostgresRowSequence) async throws -> InventoryResource {
        for try await row in rows.decode((UUID,UUID,String,String,Int,Bool).self) {
            guard let kind = InventoryResourceKind(rawValue: row.2) else { throw InventoryError.unavailable }
            return .init(facilityID: row.0,id: row.1,kind: kind,name: row.3,capacity: row.4,enabled: row.5)
        }
        throw InventoryError.notAvailable
    }
    private func claimRow(_ rows: PostgresRowSequence) async throws -> InventoryClaim {
        for try await row in rows.decode((UUID,UUID,UUID,String,UUID,Int,Date,Date,Int?,Int?,Date?).self) {
            guard let kind = ProductKind(rawValue: row.3) else { throw InventoryError.unavailable }
            let seats: InventorySeats
            if kind == .sharedSauna {
                guard let lower = row.8, let upper = row.9, lower >= 0, upper <= row.5, upper-lower == 1 else {
                    throw InventoryError.unavailable
                }
                seats = .sharedSeat(lower)
            } else {
                guard row.8 == nil, row.9 == nil else { throw InventoryError.unavailable }
                seats = .wholeResource
            }
            return .init(facilityID: row.0,id: row.1,productID: row.2,productKind: kind,resourceID: row.4,
                         capacity: row.5,interval: try .init(startsAt: row.6,endsAt: row.7),seats: seats,releasedAt: row.10)
        }
        throw InventoryError.notAvailable
    }
    private func query(_ query: PostgresQuery) async throws -> PostgresRowSequence {
        try Task.checkCancellation()
        let logger = Logger(label: "SaunaInventory") { _ in SwiftLogNoOpLogHandler() }
        return try await connection.query(query, logger: logger)
    }
}
