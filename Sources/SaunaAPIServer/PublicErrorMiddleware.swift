import HTTPTypes
import OpenAPIRuntime

struct PublicErrorMiddleware: ServerMiddleware {
  func intercept(
    _ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
    next:
      @concurrent @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (
        HTTPResponse, HTTPBody?
      )
  ) async throws -> (HTTPResponse, HTTPBody?) {
    do {
      return try await next(request, body, metadata)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ServerError {
      if error.underlyingError is CancellationError { throw CancellationError() }
      // Runtime error bodies and headers can reflect request data.
      let code = error.httpStatus.code
      let status: HTTPResponse.Status =
        (400...599).contains(code) ? .init(code: code) : .internalServerError
      return (.init(status: status), nil)
    } catch {
      return (.init(status: .internalServerError), nil)
    }
  }
}
