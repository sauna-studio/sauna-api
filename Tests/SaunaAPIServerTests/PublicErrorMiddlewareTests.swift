import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import SaunaAPIServer

struct PublicErrorMiddlewareTests {
  private struct SyntheticFailure: Error {}

  @Test(arguments: [(406, 406), (200, 500)])
  func thrownServerErrorsKeepOnlyTheirErrorStatusCode(input: Int, expected: Int) async throws {
    let marker = "synthetic-private-error-marker"
    let request = HTTPRequest(
      method: .get, scheme: nil, authority: nil, path: "/?probe=\(marker)",
      headerFields: [.authorization: marker])
    let (response, body) = try await PublicErrorMiddleware().intercept(
      request, body: nil, metadata: .init(), operationID: "getHealth",
      next: { request, _, metadata in
        throw ServerError(
          operationID: marker, request: request, requestBody: HTTPBody(marker),
          requestMetadata: metadata, operationInput: marker, causeDescription: marker,
          underlyingError: SyntheticFailure(), httpStatus: .init(code: input, reasonPhrase: marker),
          httpHeaderFields: [.authorization: marker], httpBody: HTTPBody(marker))
      })
    #expect(response.status.code == expected)
    #expect(!response.status.reasonPhrase.contains(marker))
    #expect(response.headerFields.isEmpty)
    #expect(body == nil)
  }

  @Test func unknownErrorsReturnAnEmptyInternalServerError() async throws {
    let (response, body) = try await PublicErrorMiddleware().intercept(
      .init(method: .get, scheme: nil, authority: nil, path: "/health"),
      body: nil, metadata: .init(), operationID: "getHealth",
      next: { _, _, _ in throw SyntheticFailure() })
    #expect(response.status == .internalServerError)
    #expect(response.headerFields.isEmpty)
    #expect(body == nil)
  }

  @Test(arguments: [false, true])
  func cancellationRemainsCancellation(wrapped: Bool) async {
    await #expect(throws: CancellationError.self) {
      try await PublicErrorMiddleware().intercept(
        .init(method: .get, scheme: nil, authority: nil, path: "/health"),
        body: nil, metadata: .init(), operationID: "getHealth",
        next: { request, _, metadata in
          if wrapped {
            throw ServerError(
              operationID: "getHealth", request: request, requestBody: nil,
              requestMetadata: metadata, causeDescription: "cancelled",
              underlyingError: CancellationError())
          }
          throw CancellationError()
        })
    }
  }

  @Test func returnedResponsesPreserveTheirBodyAndHeaders() async throws {
    let expected = HTTPResponse(
      status: .serviceUnavailable,
      headerFields: [.contentType: "application/problem+json", .setCookie: "synthetic-cookie"])
    let expectedBody = HTTPBody("synthetic-public-problem")
    let (response, body) = try await PublicErrorMiddleware().intercept(
      .init(method: .get, scheme: nil, authority: nil, path: "/health"),
      body: nil, metadata: .init(), operationID: "getHealth",
      next: { _, _, _ in (expected, expectedBody) })
    #expect(response == expected)
    #expect(body === expectedBody)
  }
}
