import Foundation
public import SaunaAPIContract
import SaunaAPIIdentity

extension ServiceAPI {
  private func managementResources() throws -> (AuthRequestContext, PasskeyManagementService, AuthSessionToken) {
    guard let client = authenticationClient else { throw AuthenticationError.unavailable }
    guard let context = AuthRequestContext.current else { throw AuthenticationError.rejected }
    return (context, try .init(client: client, relyingParty: context.relyingParty), try context.token())
  }
  private func managementCSRF(_ context: AuthRequestContext) throws -> String {
    guard let value = context.csrfToken else { throw AuthenticationError.rejected }
    return value
  }
  private func managementFinish(_ value: Components.Schemas.PasskeyFinishRequest) throws -> (UUID, Data) {
    guard let id = UUID(uuidString: value.challengeID), value.credentialJSON.utf8.count <= 65_536 else { throw AuthenticationError.invalidInput }
    return (id, Data(value.credentialJSON.utf8))
  }
  private func managementOptions(_ options: PasskeyOptions) throws -> Components.Schemas.PasskeyOptionsResponse {
    .init(challengeID: options.challengeID.uuidString, publicKey: try JSONDecoder().decode(Components.Schemas.PasskeyOptionsResponse.PublicKeyPayload.self, from: options.optionsJSON))
  }
  public func listPasskeys(_ input: Operations.ListPasskeys.Input) async throws -> Operations.ListPasskeys.Output {
    do {
      let (_, service, token) = try managementResources()
      let credentials = try await service.list(token: token).map {
        Components.Schemas.ManagedPasskey(credentialID: $0.credentialID, createdAtUnixSeconds: Int64($0.createdAt.timeIntervalSince1970), lastUsedAtUnixSeconds: $0.lastUsedAt.map { Int64($0.timeIntervalSince1970) }, isCurrentSessionCredential: $0.isCurrentSessionCredential)
      }
      return .ok(.init(body: .json(.init(credentials: credentials))))
    } catch { throw authHTTPError(error) }
  }
  public func beginPasskeyAdditionAuthorization(_ input: Operations.BeginPasskeyAdditionAuthorization.Input) async throws -> Operations.BeginPasskeyAdditionAuthorization.Output {
    do {
      let (context, service, token) = try managementResources()
      let options = try await service.beginAddition(token: token, csrfToken: managementCSRF(context))
      return .ok(.init(body: .json(try managementOptions(options))))
    } catch { throw authHTTPError(error) }
  }
  public func finishPasskeyAdditionAuthorization(_ input: Operations.FinishPasskeyAdditionAuthorization.Input) async throws -> Operations.FinishPasskeyAdditionAuthorization.Output {
    do {
      let (context, service, token) = try managementResources()
      let value: Components.Schemas.PasskeyFinishRequest
      switch input.body { case .json(let body): value = body }
      let (id, credential) = try managementFinish(value)
      let options = try await service.authorizeAddition(challengeID: id, credentialJSON: credential, token: token, csrfToken: managementCSRF(context))
      return .ok(.init(body: .json(try managementOptions(options))))
    } catch { throw authHTTPError(error) }
  }
  public func finishPasskeyAddition(_ input: Operations.FinishPasskeyAddition.Input) async throws -> Operations.FinishPasskeyAddition.Output {
    do {
      let (context, service, token) = try managementResources()
      let value: Components.Schemas.PasskeyFinishRequest
      switch input.body { case .json(let body): value = body }
      let (id, credential) = try managementFinish(value)
      try await service.finishAddition(challengeID: id, credentialJSON: credential, token: token, csrfToken: managementCSRF(context))
      context.setCookie(name: context.sessionName, value: "", maxAge: 0)
      return .noContent(.init(headers: .init()))
    } catch { throw authHTTPError(error) }
  }
  public func beginPasskeyRevocation(_ input: Operations.BeginPasskeyRevocation.Input) async throws -> Operations.BeginPasskeyRevocation.Output {
    do {
      let (context, service, token) = try managementResources()
      let value: Components.Schemas.PasskeyRevocationRequest
      switch input.body { case .json(let body): value = body }
      let options = try await service.beginRevocation(credentialID: value.credentialID, token: token, csrfToken: managementCSRF(context))
      return .ok(.init(body: .json(try managementOptions(options))))
    } catch { throw authHTTPError(error) }
  }
  public func finishPasskeyRevocation(_ input: Operations.FinishPasskeyRevocation.Input) async throws -> Operations.FinishPasskeyRevocation.Output {
    do {
      let (context, service, token) = try managementResources()
      let value: Components.Schemas.PasskeyFinishRequest
      switch input.body { case .json(let body): value = body }
      let (id, credential) = try managementFinish(value)
      try await service.finishRevocation(challengeID: id, credentialJSON: credential, token: token, csrfToken: managementCSRF(context))
      context.setCookie(name: context.sessionName, value: "", maxAge: 0)
      return .noContent(.init(headers: .init()))
    } catch { throw authHTTPError(error) }
  }
}
