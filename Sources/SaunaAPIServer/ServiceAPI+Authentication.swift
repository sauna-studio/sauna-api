import Foundation
public import SaunaAPIContract
import SaunaAPIIdentity

extension ServiceAPI {
  private func authResources() throws -> (AuthRequestContext, PasskeyAuthService, SessionStore) {
    guard let client = authenticationClient else { throw AuthenticationError.unavailable }
    guard let context = AuthRequestContext.current else { throw AuthenticationError.rejected }
    return (
      context, try .init(client: client, relyingParty: context.relyingParty),
      .init(client: client, relyingParty: context.relyingParty)
    )
  }
  private func optionsBody(_ value: PasskeyOptions) throws
    -> Components.Schemas.PasskeyOptionsResponse
  {
    .init(
      challengeID: value.challengeID.uuidString,
      publicKey: try JSONDecoder().decode(
        Components.Schemas.PasskeyOptionsResponse.PublicKeyPayload.self, from: value.optionsJSON))
  }
  private func sessionBody(_ value: AuthenticatedSession) -> Components.Schemas.AuthSession {
    .init(
      userID: value.subject.userID.uuidString,
      expiresAtUnixSeconds: Int64(value.expiresAt.timeIntervalSince1970), csrfToken: value.csrfToken
    )
  }
  private func finishBody(_ value: Components.Schemas.PasskeyFinishRequest) throws -> (UUID, Data) {
    guard let id = UUID(uuidString: value.challengeID), value.credentialJSON.utf8.count <= 65_536
    else { throw AuthenticationError.invalidInput }
    return (id, Data(value.credentialJSON.utf8))
  }
  public func beginPasskeyRegistration(_ input: Operations.BeginPasskeyRegistration.Input)
    async throws -> Operations.BeginPasskeyRegistration.Output
  {
    do {
      let (context, auth, _) = try authResources()
      let binding = PasskeyFlowBinding.generate()
      let options = try await auth.beginRegistration(binding: binding)
      context.setCookie(name: context.flowName, value: binding.encoded, maxAge: 300)
      return .ok(.init(headers: .init(), body: .json(try optionsBody(options))))
    } catch { throw authHTTPError(error) }
  }
  public func finishPasskeyRegistration(_ input: Operations.FinishPasskeyRegistration.Input)
    async throws -> Operations.FinishPasskeyRegistration.Output
  {
    do {
      let (context, auth, _) = try authResources()
      let value: Components.Schemas.PasskeyFinishRequest
      switch input.body {
      case .json(let body): value = body
      }
      let (id, credential) = try finishBody(value)
      try await auth.finishRegistration(
        challengeID: id, binding: context.binding(), credentialJSON: credential)
      return .noContent(.init())
    } catch { throw authHTTPError(error) }
  }
  public func beginPasskeyAuthentication(_ input: Operations.BeginPasskeyAuthentication.Input)
    async throws -> Operations.BeginPasskeyAuthentication.Output
  {
    do {
      let (context, auth, _) = try authResources()
      let binding = PasskeyFlowBinding.generate()
      let options = try await auth.beginAuthentication(binding: binding)
      context.setCookie(name: context.flowName, value: binding.encoded, maxAge: 300)
      return .ok(.init(headers: .init(), body: .json(try optionsBody(options))))
    } catch { throw authHTTPError(error) }
  }
  public func finishPasskeyAuthentication(_ input: Operations.FinishPasskeyAuthentication.Input)
    async throws -> Operations.FinishPasskeyAuthentication.Output
  {
    do {
      let (context, auth, _) = try authResources()
      let value: Components.Schemas.PasskeyFinishRequest
      switch input.body {
      case .json(let body): value = body
      }
      let (id, credential) = try finishBody(value)
      let grant = try await auth.finishAuthentication(
        challengeID: id, binding: context.binding(), credentialJSON: credential)
      context.setCookie(name: context.sessionName, value: grant.token.encoded, maxAge: 28_800)
      return .ok(.init(headers: .init(), body: .json(sessionBody(grant.session))))
    } catch { throw authHTTPError(error) }
  }
  public func getAuthSession(_ input: Operations.GetAuthSession.Input) async throws
    -> Operations.GetAuthSession.Output
  {
    do {
      let (context, _, sessions) = try authResources()
      return .ok(
        .init(body: .json(sessionBody(try await sessions.resolve(token: context.token())))))
    } catch { throw authHTTPError(error) }
  }
  public func logoutSession(_ input: Operations.LogoutSession.Input) async throws
    -> Operations.LogoutSession.Output
  {
    do {
      let (context, _, sessions) = try authResources()
      guard let csrf = context.csrfToken else { throw AuthenticationError.rejected }
      try await sessions.revoke(token: context.token(), csrfToken: csrf)
      context.setCookie(name: context.sessionName, value: "", maxAge: 0)
      return .noContent(.init(headers: .init()))
    } catch { throw authHTTPError(error) }
  }
  public func revokeAllSessions(_ input: Operations.RevokeAllSessions.Input) async throws
    -> Operations.RevokeAllSessions.Output
  {
    do {
      let (context, _, sessions) = try authResources()
      guard let csrf = context.csrfToken else { throw AuthenticationError.rejected }
      try await sessions.revokeAll(token: context.token(), csrfToken: csrf)
      context.setCookie(name: context.sessionName, value: "", maxAge: 0)
      return .noContent(.init(headers: .init()))
    } catch { throw authHTTPError(error) }
  }
}
