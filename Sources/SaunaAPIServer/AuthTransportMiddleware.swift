import Foundation
import HTTPTypes
import OpenAPIRuntime
import SaunaAPIIdentity
import Synchronization

struct AuthHTTPFailure: Error, HTTPResponseConvertible {
  let status: HTTPResponse.Status
  var httpStatus: HTTPResponse.Status { status }
  var httpBody: HTTPBody? {
    let title: String
    switch status.code {
    case 400: title = "Bad Request"
    case 401: title = "Unauthorized"
    case 403: title = "Forbidden"
    case 413: title = "Payload Too Large"
    case 429: title = "Too Many Requests"
    default: title = "Service Unavailable"
    }
    return HTTPBody("{\"type\":\"about:blank\",\"title\":\"\(title)\",\"status\":\(status.code)}")
  }
  var httpHeaderFields: HTTPFields {
    [
      .contentType: "application/problem+json", .cacheControl: "no-store",
      HTTPField.Name("X-Content-Type-Options")!: "nosniff",
      HTTPField.Name("Content-Security-Policy")!: "frame-ancestors 'none'",
    ]
  }
  func response() -> (HTTPResponse, HTTPBody?) {
    (.init(status: status, headerFields: httpHeaderFields), httpBody)
  }
}

final class AuthResponseCookie: Sendable {
  let value = Mutex<String?>(nil)
}

struct AuthRequestContext: Sendable, CustomStringConvertible {
  @TaskLocal static var current: AuthRequestContext?
  let relyingParty: LocalPasskeyRelyingParty
  let cookies: [String: String]
  let csrfToken: String?
  let responseCookie = AuthResponseCookie()
  var description: String { "AuthRequestContext(<redacted>)" }
  var profile: String { relyingParty.origin.hasSuffix(":5173") ? "customer" : "staff" }
  var flowName: String { "__Host-sauna-\(profile)-flow" }
  var sessionName: String { "__Host-sauna-\(profile)-session" }
  func binding() throws -> PasskeyFlowBinding {
    guard let raw = cookies[flowName] else { throw AuthenticationError.rejected }
    do { return try .init(encoded: raw) } catch { throw AuthenticationError.rejected }
  }
  func token() throws -> AuthSessionToken {
    guard let raw = cookies[sessionName] else { throw AuthenticationError.rejected }
    do { return try .init(encoded: raw) } catch { throw AuthenticationError.rejected }
  }
  func setCookie(name: String, value: String, maxAge: Int) {
    responseCookie.value.withLock {
      $0 = "\(name)=\(value); Path=/; Max-Age=\(maxAge); Secure; HttpOnly; SameSite=Strict"
    }
  }
}

actor AuthRequestLimiter {
  private var buckets: [String: (ContinuousClock.Instant, Int)] = [:]
  private let limit: Int
  init(limit: Int = 240) { self.limit = limit }
  func allow(_ origin: String) -> Bool {
    let now = ContinuousClock.now
    let old = buckets[origin]
    if let old, old.0.duration(to: now) < .seconds(60) {
      guard old.1 < limit else { return false }
      buckets[origin] = (old.0, old.1 + 1)
    } else {
      buckets[origin] = (now, 1)
    }
    return true
  }
}

/// Cookie handling is explicit because the pinned generator does not support
/// cookie parameters. No cookie/token values enter exception descriptions/logs.
struct AuthTransportMiddleware: ServerMiddleware {
  let limiter: AuthRequestLimiter
  init(limiter: AuthRequestLimiter = .init()) { self.limiter = limiter }
  func intercept(
    _ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
    next:
      @concurrent @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
        HTTPResponse, HTTPBody?
      )
  ) async throws -> (HTTPResponse, HTTPBody?) {
    guard operationID != "getHealth", operationID != "getVersion" else {
      return try await next(request, body, metadata)
    }
    do {
      let origins = request.headerFields.filter { $0.name == .origin }
      guard origins.count == 1 else { throw AuthHTTPFailure(status: .forbidden) }
      let origin = origins[0].value
      let party: LocalPasskeyRelyingParty
      switch origin {
      case "http://localhost:5173": party = .customer
      case "http://localhost:5174": party = .staff
      default: throw AuthHTTPFailure(status: .forbidden)
      }
      guard await limiter.allow(origin) else { throw AuthHTTPFailure(status: .tooManyRequests) }
      if let site = request.headerFields[HTTPField.Name("Sec-Fetch-Site")!], site != "same-origin",
        site != "none"
      {
        throw AuthHTTPFailure(status: .forbidden)
      }
      let csrfName = HTTPField.Name("X-Sauna-CSRF")!
      guard request.headerFields.filter({ $0.name == csrfName }).count <= 1 else {
        throw AuthHTTPFailure(status: .badRequest)
      }
      var cookies: [String: String] = [:]
      for header in request.headerFields.filter({ $0.name == .cookie }) {
        for piece in header.value.split(separator: ";") {
          let bits = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
          guard bits.count == 2 else { throw AuthHTTPFailure(status: .badRequest) }
          let name = bits[0].trimmingCharacters(in: .whitespaces)
          guard name.hasPrefix("__Host-sauna-") else { continue }
          guard cookies[name] == nil else { throw AuthHTTPFailure(status: .badRequest) }
          cookies[name] = String(bits[1])
        }
      }
      var replay: HTTPBody?
      if let body {
        let bytes: Data
        do {
          bytes = try await authenticationDeadline {
            var collected = Data()
            for try await chunk in body {
              guard chunk.count <= 131_072 - collected.count else {
                throw AuthHTTPFailure(status: .contentTooLarge)
              }
              collected.append(contentsOf: chunk)
            }
            return collected
          }
        } catch is CancellationError { throw CancellationError() } catch let failure
          as AuthHTTPFailure
        { throw failure } catch { throw AuthHTTPFailure(status: .serviceUnavailable) }
        if !bytes.isEmpty {
          guard
            request.headerFields[.contentType]?.split(separator: ";").first?.lowercased()
              == "application/json"
          else { throw AuthHTTPFailure(status: .badRequest) }
          do {
            try validateAuthenticationTransportJSON(
              bytes, finish: operationID.hasSuffix("Finish") || operationID.hasPrefix("finish"))
          } catch { throw AuthHTTPFailure(status: .badRequest) }
        }
        replay = HTTPBody(bytes)
      }
      let context = AuthRequestContext(
        relyingParty: party, cookies: cookies, csrfToken: request.headerFields[csrfName])
      let replayBody = replay
      let result = try await AuthRequestContext.$current.withValue(context) {
        try await next(request, replayBody, metadata)
      }
      try Task.checkCancellation()
      var response = result.0
      if response.status.code >= 400 {
        let allowed = [400, 401, 403, 413, 429, 503]
        let status =
          allowed.contains(response.status.code)
          ? response.status
          : (response.status.code >= 500 ? HTTPResponse.Status.serviceUnavailable : .badRequest)
        return AuthHTTPFailure(status: status).response()
      }
      if let cookie = context.responseCookie.value.withLock({ $0 }) {
        response.headerFields[.setCookie] = cookie
      }
      response.headerFields[.cacheControl] = "no-store"
      response.headerFields[HTTPField.Name("X-Content-Type-Options")!] = "nosniff"
      response.headerFields[HTTPField.Name("Content-Security-Policy")!] = "frame-ancestors 'none'"
      return (response, result.1)
    } catch is CancellationError { throw CancellationError() } catch let failure as AuthHTTPFailure
    { return failure.response() } catch {
      if Task.isCancelled { throw CancellationError() }
      return AuthHTTPFailure(status: .serviceUnavailable).response()
    }
  }
}

func authHTTPError(_ error: any Error) -> any Error {
  if error is CancellationError || Task.isCancelled { return CancellationError() }
  if let error = error as? AuthenticationError {
    switch error {
    case .invalidInput: return AuthHTTPFailure(status: .badRequest)
    case .rejected: return AuthHTTPFailure(status: .unauthorized)
    case .unavailable: return AuthHTTPFailure(status: .serviceUnavailable)
    }
  }
  return AuthHTTPFailure(status: .serviceUnavailable)
}
