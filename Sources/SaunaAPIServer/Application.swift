public import Hummingbird
import SaunaAPIContract
import OpenAPIHummingbird
import OpenAPIRuntime

public func makeApplication(
    configuration: ServerConfiguration,
    api: ServiceAPI = .init()
) throws -> some ApplicationProtocol {
    let router = Router()
    // The standard runtime middleware returns status-only responses for conversion failures;
    // it does not stringify ServerError, which may contain request headers and query values.
    try api.registerHandlers(on: router, middlewares: [ErrorHandlingMiddleware()])
    return Application(
        router: router,
        configuration: .init(
            address: .hostname(configuration.bindHost, port: configuration.port),
            serverName: nil
        )
    )
}
