public import Foundation
public import PostgresNIO
import SaunaAPIIdentity

public struct ProductCatalogService: Sendable {
    private let client: PostgresClient
    public init(client: PostgresClient) { self.client = client }
    public func products(facilityID: UUID, kind: ProductKind? = nil, limit: Int = 100) async throws -> [CatalogProduct] {
        try await withStore { try await $0.publishedProducts(facilityID: facilityID, kind: kind, limit: limit) }
    }
    public func product(facilityID: UUID, id: UUID) async throws -> CatalogProduct {
        try await withStore { try await $0.publishedProduct(facilityID: facilityID, id: id) }
    }
    private func withStore<Value: Sendable>(operation: @escaping @concurrent @Sendable (ProductCatalogStore) async throws -> Value) async throws -> Value {
        do {
            return try await authenticationDeadline {
                try await authenticationConnection(client) { connection in
                    try await operation(.init(connection: connection))
                }
            }
        } catch { throw catalogError(error) }
    }
}

func catalogError(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let error = error as? FacilityStoreError { return error }
    if let error = error as? AuthenticationError { return error }
    return FacilityStoreError.unavailable
}
