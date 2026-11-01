import Foundation
import SaunaAPIDatabase
import SaunaAPIIdentity
public import SaunaAPIContract

extension ServiceAPI {
    private func catalogService() throws -> ProductCatalogService {
        guard let client = authenticationClient else { throw FacilityStoreError.unavailable }
        return .init(client: client)
    }
    private func catalogProduct(_ value: CatalogProduct) throws -> Components.Schemas.ProductOffering {
        let conditions = value.conditions
        guard let kind = Components.Schemas.ProductKind(rawValue: conditions.kind.rawValue) else { throw FacilityStoreError.unavailable }
        return .init(facilityID: value.facilityID.uuidString, id: value.id.uuidString, name: value.name,
                     kind: kind, capacity: conditions.capacity, minimumDurationMinutes: conditions.minimumDurationMinutes,
                     maximumDurationMinutes: conditions.maximumDurationMinutes, minimumNights: conditions.minimumNights,
                     maximumNights: conditions.maximumNights, published: value.published)
    }
    private func productKind(_ value: Components.Schemas.ProductKind?) throws -> SaunaAPIDatabase.ProductKind? {
        guard let value else { return nil }
        guard let kind = SaunaAPIDatabase.ProductKind(rawValue: value.rawValue) else { throw FacilityStoreError.invalidInput }
        return kind
    }
    public func getPublishedProducts(_ input: Operations.GetPublishedProducts.Input) async throws -> Operations.GetPublishedProducts.Output {
        do {
            let values = try await catalogService().products(facilityID: facilityID(input.path.facilityID), kind: productKind(input.query.kind), limit: input.query.limit ?? 100)
            return .ok(.init(body: .json(.init(products: try values.map(catalogProduct)))))
        } catch { throw facilityHTTPError(error) }
    }
    public func getPublishedProduct(_ input: Operations.GetPublishedProduct.Input) async throws -> Operations.GetPublishedProduct.Output {
        do {
            let value = try await catalogService().product(facilityID: facilityID(input.path.facilityID), id: facilityID(input.path.productID))
            return .ok(.init(body: .json(try catalogProduct(value))))
        } catch { throw facilityHTTPError(error) }
    }
    public func staffListOfferings(_ input: Operations.StaffListOfferings.Input) async throws -> Operations.StaffListOfferings.Output {
        do {
            let (service, _) = try facilityService()
            let published = input.query.publication.map { $0.rawValue == "published" }
            let values = try await service.listOfferings(facilityID: facilityID(input.path.facilityID), kind: productKind(input.query.kind), published: published, limit: input.query.limit ?? 100)
            return .ok(.init(body: .json(.init(products: try values.map(catalogProduct)))))
        } catch { throw facilityHTTPError(error) }
    }
    public func staffGetOffering(_ input: Operations.StaffGetOffering.Input) async throws -> Operations.StaffGetOffering.Output {
        do {
            let (service, _) = try facilityService()
            let value = try await service.offering(facilityID: facilityID(input.path.facilityID), id: facilityID(input.path.productID))
            return .ok(.init(body: .json(try catalogProduct(value))))
        } catch { throw facilityHTTPError(error) }
    }
    public func staffSetOffering(_ input: Operations.StaffSetOffering.Input) async throws -> Operations.StaffSetOffering.Output {
        do {
            let (service, context) = try facilityService()
            guard let csrf = context.csrfToken else { throw AuthenticationError.rejected }
            let body: Components.Schemas.ProductOfferingRequest
            switch input.body { case .json(let value): body = value }
            guard let kind = try productKind(body.kind) else { throw FacilityStoreError.invalidInput }
            let conditions = try ProductConditions(kind: kind, capacity: body.capacity,
                minimumDurationMinutes: body.minimumDurationMinutes, maximumDurationMinutes: body.maximumDurationMinutes,
                minimumNights: body.minimumNights, maximumNights: body.maximumNights)
            let value = try await service.setOffering(facilityID: facilityID(input.path.facilityID), id: facilityID(input.path.productID),
                                                      conditions: conditions, published: body.published, csrfToken: csrf)
            return .ok(.init(body: .json(try catalogProduct(value))))
        } catch { throw facilityHTTPError(error) }
    }
}
