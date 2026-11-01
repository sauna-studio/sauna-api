import Foundation
import Logging
import PostgresNIO
import SaunaAPIIdentity

struct ProductCatalogStore: Sendable {
    private let connection: PostgresConnection
    private let subjectID: UUID?
    private let sessionHash: Data?
    private let origin: String?

    init(connection: PostgresConnection) {
        self.connection = connection
        subjectID = nil
        sessionHash = nil
        origin = nil
    }
    init(connection: PostgresConnection, subject: VerifiedSubject, token: AuthSessionToken, party: LocalPasskeyRelyingParty) {
        self.connection = connection
        subjectID = subject.userID
        sessionHash = token.digest
        origin = party.origin
    }

    func publishedProducts(facilityID: UUID, kind: ProductKind?, limit: Int) async throws -> [CatalogProduct] {
        try validateLimit(limit)
        return try await products("""
            SELECT p.facility_id,p.id,p.name,p.published,o.kind,o.capacity,o.minimum_duration_minutes,
                   o.maximum_duration_minutes,o.minimum_nights,o.maximum_nights
            FROM public.products AS p
            JOIN public.product_offerings AS o ON o.facility_id=p.facility_id AND o.product_id=p.id AND o.kind=p.kind
            WHERE p.facility_id=\(facilityID) AND p.published=true
              AND (\(kind?.rawValue)::text IS NULL OR p.kind=\(kind?.rawValue))
            ORDER BY p.id LIMIT \(limit)
            """)
    }
    func publishedProduct(facilityID: UUID, id: UUID) async throws -> CatalogProduct {
        let values = try await products("""
            SELECT p.facility_id,p.id,p.name,p.published,o.kind,o.capacity,o.minimum_duration_minutes,
                   o.maximum_duration_minutes,o.minimum_nights,o.maximum_nights
            FROM public.products AS p
            JOIN public.product_offerings AS o ON o.facility_id=p.facility_id AND o.product_id=p.id AND o.kind=p.kind
            WHERE p.facility_id=\(facilityID) AND p.id=\(id) AND p.published=true
            """)
        guard let value = values.first else { throw FacilityStoreError.notAvailable }
        return value
    }

    func staffProducts(facilityID: UUID, kind: ProductKind?, published: Bool?, limit: Int) async throws -> [CatalogProduct] {
        try validateLimit(limit)
        let rows = try await query("""
            SELECT p.facility_id,p.id,p.name,p.published,o.kind,o.capacity,o.minimum_duration_minutes,
                   o.maximum_duration_minutes,o.minimum_nights,o.maximum_nights
            FROM public.facility_memberships AS m
            LEFT JOIN (public.products AS p JOIN public.product_offerings AS o
              ON o.facility_id=p.facility_id AND o.product_id=p.id AND o.kind=p.kind)
              ON p.facility_id=m.facility_id
              AND (\(kind?.rawValue)::text IS NULL OR p.kind=\(kind?.rawValue))
              AND (\(published)::boolean IS NULL OR p.published=\(published))
            WHERE m.facility_id=\(facilityID) AND m.user_id=\(subjectID)
              AND m.status='active' AND m.role IN ('owner','manager','staff')
              AND EXISTS (
                SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                  ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp()
              )
            ORDER BY p.id LIMIT \(limit)
            """)
        var authorized = false
        var values: [CatalogProduct] = []
        for try await row in rows.decode((UUID?, UUID?, String?, Bool?, String?, Int?, Int?, Int?, Int?, Int?).self) {
            authorized = true
            if let facility = row.0, let id = row.1, let name = row.2, let publication = row.3,
               let kind = row.4, let capacity = row.5, let minimumDuration = row.6,
               let maximumDuration = row.7, let minimumNights = row.8, let maximumNights = row.9 {
                values.append(try product(facility, id, name, publication, kind, capacity, minimumDuration, maximumDuration, minimumNights, maximumNights))
            }
        }
        guard authorized else { throw FacilityStoreError.notAvailable }
        return values
    }

    func staffProduct(facilityID: UUID, id: UUID) async throws -> CatalogProduct {
        let values = try await products("""
            SELECT p.facility_id,p.id,p.name,p.published,o.kind,o.capacity,o.minimum_duration_minutes,
                   o.maximum_duration_minutes,o.minimum_nights,o.maximum_nights
            FROM public.products AS p JOIN public.product_offerings AS o
              ON o.facility_id=p.facility_id AND o.product_id=p.id AND o.kind=p.kind
            WHERE p.facility_id=\(facilityID) AND p.id=\(id)
              AND EXISTS (SELECT 1 FROM public.facility_memberships AS m
                WHERE m.facility_id=p.facility_id AND m.user_id=\(subjectID)
                  AND m.status='active' AND m.role IN ('owner','manager','staff'))
              AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                  ON c.id=s.credential_id AND c.user_id=s.user_id
                WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                  AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                  AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
            """)
        guard let value = values.first else { throw FacilityStoreError.notAvailable }
        return value
    }

    func setOffering(facilityID: UUID, id: UUID, conditions: ProductConditions, published: Bool) async throws -> CatalogProduct {
        let values = try await products("""
            WITH authorized AS MATERIALIZED (
                SELECT p.facility_id,p.id,p.kind FROM public.products AS p
                WHERE p.facility_id=\(facilityID) AND p.id=\(id) AND p.kind=\(conditions.kind.rawValue)
                  AND EXISTS (SELECT 1 FROM public.facility_memberships AS m
                    WHERE m.facility_id=p.facility_id AND m.user_id=\(subjectID)
                      AND m.status='active' AND m.role IN ('owner','manager'))
                  AND EXISTS (SELECT 1 FROM public.auth_sessions AS s JOIN public.passkey_credentials AS c
                    ON c.id=s.credential_id AND c.user_id=s.user_id
                    WHERE s.token_hash=\(sessionHash) AND s.user_id=\(subjectID) AND s.origin=\(origin)
                      AND s.revoked_at IS NULL AND c.revoked_at IS NULL
                      AND s.created_at<=clock_timestamp() AND s.expires_at>clock_timestamp())
                FOR UPDATE OF p
            ), offering AS (
                INSERT INTO public.product_offerings(facility_id,product_id,kind,capacity,minimum_duration_minutes,
                    maximum_duration_minutes,minimum_nights,maximum_nights)
                SELECT facility_id,id,kind,\(conditions.capacity),\(conditions.minimumDurationMinutes),
                    \(conditions.maximumDurationMinutes),\(conditions.minimumNights),\(conditions.maximumNights) FROM authorized
                ON CONFLICT (facility_id,product_id) DO UPDATE SET kind=EXCLUDED.kind,capacity=EXCLUDED.capacity,
                    minimum_duration_minutes=EXCLUDED.minimum_duration_minutes,maximum_duration_minutes=EXCLUDED.maximum_duration_minutes,
                    minimum_nights=EXCLUDED.minimum_nights,maximum_nights=EXCLUDED.maximum_nights
                RETURNING *
            ), publication AS (
                UPDATE public.products AS p SET published=\(published)
                WHERE p.facility_id=\(facilityID) AND p.id=\(id)
                  AND EXISTS (SELECT 1 FROM offering AS o WHERE o.facility_id=p.facility_id AND o.product_id=p.id)
                RETURNING p.facility_id,p.id,p.name,p.published
            )
            SELECT p.facility_id,p.id,p.name,p.published,o.kind,o.capacity,o.minimum_duration_minutes,
                   o.maximum_duration_minutes,o.minimum_nights,o.maximum_nights
            FROM publication AS p JOIN offering AS o ON o.facility_id=p.facility_id AND o.product_id=p.id
            """)
        guard let value = values.first else { throw FacilityStoreError.notAvailable }
        return value
    }

    private func validateLimit(_ value: Int) throws {
        guard (1...100).contains(value) else { throw FacilityStoreError.invalidInput }
    }
    private func products(_ sql: PostgresQuery) async throws -> [CatalogProduct] {
        var values: [CatalogProduct] = []
        let rows = try await query(sql)
        for try await row in rows.decode((UUID, UUID, String, Bool, String, Int, Int, Int, Int, Int).self) {
            values.append(try product(row.0,row.1,row.2,row.3,row.4,row.5,row.6,row.7,row.8,row.9))
        }
        return values
    }
    private func product(_ facility: UUID, _ id: UUID, _ name: String, _ published: Bool, _ rawKind: String,
                         _ capacity: Int, _ minDuration: Int, _ maxDuration: Int, _ minNights: Int, _ maxNights: Int) throws -> CatalogProduct {
        guard let kind = ProductKind(rawValue: rawKind),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.unicodeScalars.count <= 200 else { throw FacilityStoreError.unavailable }
        do {
            return .init(facilityID: facility, id: id, name: name, published: published,
                         conditions: try .init(kind: kind, capacity: capacity, minimumDurationMinutes: minDuration,
                                               maximumDurationMinutes: maxDuration, minimumNights: minNights, maximumNights: maxNights))
        } catch { throw FacilityStoreError.unavailable }
    }
    private func query(_ sql: PostgresQuery) async throws -> PostgresRowSequence {
        try Task.checkCancellation()
        let logger = Logger(label: "SaunaCatalog") { _ in SwiftLogNoOpLogHandler() }
        return try await connection.query(sql, logger: logger)
    }
}
