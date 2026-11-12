public import Hummingbird
import SaunaAPIContract
import OpenAPIHummingbird
import OpenAPIRuntime
public import ServiceLifecycle

public func makeApplication(
    configuration: ServerConfiguration,
    api: ServiceAPI = .init(),
    services: [any Service] = [],
    traceHTTP: Bool = false
) throws -> some ApplicationProtocol {
    let router = Router()
    // The standard runtime middleware returns status-only responses for conversion failures;
    // it does not stringify ServerError, which may contain request headers and query values.
    var middlewares: [any ServerMiddleware] = []
    if traceHTTP { middlewares.append(LocalHTTPTracingMiddleware()) }
    middlewares += [AuthTransportMiddleware(), ErrorHandlingMiddleware()]
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
