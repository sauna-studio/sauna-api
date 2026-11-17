public import Hummingbird
import OpenAPIHummingbird
import OpenAPIRuntime
import SaunaAPIContract
public import ServiceLifecycle

public func makeApplication(
  configuration: ServerConfiguration,
  api: ServiceAPI = .init(),
  services: [any Service] = [],
  traceHTTP: Bool = false
) throws -> some ApplicationProtocol {
  let router = Router()
  var middlewares: [any ServerMiddleware] = []
  if traceHTTP { middlewares.append(LocalHTTPTracingMiddleware()) }
  middlewares += [AuthTransportMiddleware(), PublicErrorMiddleware()]
  try api.registerHandlers(on: router, middlewares: middlewares)
  return Application(
    router: router,
    configuration: .init(
      address: .hostname(configuration.bindHost, port: configuration.port),
      serverName: nil
    ),
    services: services
  )
}
