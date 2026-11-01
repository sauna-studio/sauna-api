public import Foundation
public import PostgresNIO
public import SaunaAPIIdentity

/// Local fixture membership checks do not verify Workspace employment.
public struct FacilityService: Sendable {
    private let client: PostgresClient
    private let token: AuthSessionToken
    private let relyingParty: LocalPasskeyRelyingParty

    public init(client: PostgresClient, token: AuthSessionToken, relyingParty: LocalPasskeyRelyingParty) {
        self.client = client
        self.token = token
        self.relyingParty = relyingParty
    }

    public func listProducts(facilityID: UUID, limit: Int = 100) async throws -> [FacilityProduct] {
        try await withStore(facilityID: facilityID) { try await $0.listProducts(limit: limit) }
    }
    public func product(facilityID: UUID, id: UUID) async throws -> FacilityProduct {
        try await withStore(facilityID: facilityID) { try await $0.product(id: id) }
    }
    public func renameProduct(facilityID: UUID, id: UUID, name: String, csrfToken: String) async throws -> FacilityProduct {
        try token.verifyCSRF(csrfToken)
        return try await withStore(facilityID: facilityID) { try await $0.renameProduct(id: id, name: name) }
    }
    public func listOfferings(facilityID: UUID, kind: ProductKind? = nil, published: Bool? = nil, limit: Int = 100) async throws -> [CatalogProduct] {
        try await withCatalog { try await $0.staffProducts(facilityID: facilityID, kind: kind, published: published, limit: limit) }
    }
    public func offering(facilityID: UUID, id: UUID) async throws -> CatalogProduct {
        try await withCatalog { try await $0.staffProduct(facilityID: facilityID, id: id) }
    }
    public func setOffering(facilityID: UUID, id: UUID, conditions: ProductConditions, published: Bool, csrfToken: String) async throws -> CatalogProduct {
        try token.verifyCSRF(csrfToken)
        return try await withCatalog { try await $0.setOffering(facilityID: facilityID, id: id, conditions: conditions, published: published) }
    }
    private func withCatalog<Value: Sendable>(operation: @escaping @concurrent @Sendable (ProductCatalogStore) async throws -> Value) async throws -> Value {
        guard relyingParty == .staff else { throw AuthenticationError.rejected }
        do {
            return try await SessionStore(client: client, relyingParty: relyingParty).withSessionTransaction(token: token) { connection, session in
                try await operation(.init(connection: connection, subject: session.subject, token: token, party: relyingParty))
            }
        } catch { throw catalogError(error) }
    }
    private func withStore<Value: Sendable>(facilityID: UUID,
        operation: @escaping @concurrent @Sendable (FacilityStore) async throws -> Value) async throws -> Value {
        guard relyingParty == .staff else { throw AuthenticationError.rejected }
        do {
            return try await SessionStore(client: client, relyingParty: relyingParty).withSessionTransaction(token: token) { connection, session in
                try await operation(.init(connection: connection, subject: session.subject, facilityID: facilityID,
                                          sessionToken: token, relyingParty: relyingParty))
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if let error = error as? AuthenticationError { throw error }
            if let error = error as? FacilityStoreError { throw error }
            throw FacilityStoreError.unavailable
        }
    }
}
