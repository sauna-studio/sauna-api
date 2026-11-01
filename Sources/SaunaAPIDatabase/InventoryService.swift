public import Foundation
public import PostgresNIO
public import SaunaAPIIdentity

public struct InventoryService: Sendable {
    private let client: PostgresClient
    private let token: AuthSessionToken
    private let party: LocalPasskeyRelyingParty
    public init(client: PostgresClient, token: AuthSessionToken, relyingParty: LocalPasskeyRelyingParty) {
        self.client = client
        self.token = token
        party = relyingParty
    }
    public func createResource(facilityID: UUID, kind: InventoryResourceKind, name: String, capacity: Int, csrfToken: String) async throws -> InventoryResource {
        try token.verifyCSRF(csrfToken)
        return try await withStore { try await $0.createResource(facilityID: facilityID,id: UUID(),kind: kind,name: name,capacity: capacity) }
    }
    public func resource(facilityID: UUID, id: UUID) async throws -> InventoryResource {
        try await withStore { try await $0.resource(facilityID: facilityID,id: id) }
    }
    public func setResourceEnabled(facilityID: UUID, id: UUID, enabled: Bool, csrfToken: String) async throws -> InventoryResource {
        try token.verifyCSRF(csrfToken)
        return try await withStore { try await $0.setEnabled(facilityID: facilityID,id: id,enabled: enabled) }
    }
    public func linkProduct(facilityID: UUID, resourceID: UUID, productID: UUID, csrfToken: String) async throws {
        try token.verifyCSRF(csrfToken)
        try await withStore { try await $0.linkProduct(facilityID: facilityID,resourceID: resourceID,productID: productID) }
    }
    public func allocate(facilityID: UUID, resourceID: UUID, productID: UUID, interval: InventoryInterval, seats: InventorySeats, csrfToken: String) async throws -> InventoryClaim {
        try token.verifyCSRF(csrfToken)
        return try await withStore { try await $0.allocate(facilityID: facilityID,resourceID: resourceID,productID: productID,interval: interval,seats: seats) }
    }
    public func claim(facilityID: UUID, id: UUID) async throws -> InventoryClaim {
        try await withStore { try await $0.claim(facilityID: facilityID,id: id) }
    }
    public func release(facilityID: UUID, id: UUID, csrfToken: String) async throws -> InventoryClaim {
        try token.verifyCSRF(csrfToken)
        return try await withStore { try await $0.release(facilityID: facilityID,id: id) }
    }
    private func withStore<Value: Sendable>(operation: @escaping @concurrent @Sendable (InventoryStore) async throws -> Value) async throws -> Value {
        guard party == .staff else { throw AuthenticationError.rejected }
        do {
            return try await SessionStore(client: client,relyingParty: party).withSessionTransaction(token: token) { connection, session in
                try await operation(.init(connection: connection,subject: session.subject,token: token,party: party))
            }
        } catch { throw inventoryError(error) }
    }
}

func inventoryError(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let error = error as? InventoryError { return error }
    if let error = error as? AuthenticationError { return error }
    if let sql = error as? PSQLError {
        switch sql.serverInfo?[.sqlState] {
        case "23P01", "23505": return InventoryError.conflict
        case "23503", "23514", "22003", "22008": return InventoryError.invalidInput
        default: break
        }
    }
    return InventoryError.unavailable
}
