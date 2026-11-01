import Foundation
import HTTPTypes
import SaunaAPIDatabase
import SaunaAPIIdentity
public import SaunaAPIContract

extension ServiceAPI {
    private func facilityService() throws -> (FacilityService, AuthRequestContext) {
        guard let client = authenticationClient else { throw AuthenticationError.unavailable }
        guard let context = AuthRequestContext.current, context.profile == "staff" else {
            throw AuthHTTPFailure(status: .forbidden)
        }
        return (.init(client: client, token: try context.token(), relyingParty: context.relyingParty), context)
    }
    private func facilityID(_ raw: String) throws -> UUID {
        guard let id = UUID(uuidString: raw) else { throw FacilityStoreError.invalidInput }
        return id
    }
    private func facilityProduct(_ product: FacilityProduct) -> Components.Schemas.LocalFacilityProduct {
        .init(id: product.id.uuidString, name: product.name)
    }
    public func staffListProducts(_ input: Operations.StaffListProducts.Input) async throws -> Operations.StaffListProducts.Output {
        do {
            let (service, _) = try facilityService()
            let products = try await service.listProducts(facilityID: facilityID(input.path.facilityID), limit: input.query.limit ?? 100)
            return .ok(.init(body: .json(.init(products: products.map(facilityProduct)))))
        } catch { throw facilityHTTPError(error) }
    }
    public func staffGetProduct(_ input: Operations.StaffGetProduct.Input) async throws -> Operations.StaffGetProduct.Output {
        do {
            let (service, _) = try facilityService()
            let product = try await service.product(facilityID: facilityID(input.path.facilityID), id: facilityID(input.path.productID))
            return .ok(.init(body: .json(facilityProduct(product))))
        } catch { throw facilityHTTPError(error) }
    }
    public func staffRenameProduct(_ input: Operations.StaffRenameProduct.Input) async throws -> Operations.StaffRenameProduct.Output {
        do {
            let (service, context) = try facilityService()
            guard let csrf = context.csrfToken else { throw AuthenticationError.rejected }
            let name: String
            switch input.body { case .json(let value): name = value.name }
            let product = try await service.renameProduct(facilityID: facilityID(input.path.facilityID), id: facilityID(input.path.productID), name: name, csrfToken: csrf)
            return .ok(.init(body: .json(facilityProduct(product))))
        } catch { throw facilityHTTPError(error) }
    }
}

private func facilityHTTPError(_ error: any Error) -> any Error {
    if error is CancellationError || Task.isCancelled { return CancellationError() }
    if let failure = error as? AuthHTTPFailure { return failure }
    if let error = error as? FacilityStoreError {
        switch error {
        case .invalidInput: return AuthHTTPFailure(status: .badRequest)
        case .notAvailable: return AuthHTTPFailure(status: .notFound)
        case .unavailable: return AuthHTTPFailure(status: .serviceUnavailable)
        }
    }
    return authHTTPError(error)
}
