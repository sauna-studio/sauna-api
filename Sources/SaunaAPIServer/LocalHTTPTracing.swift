import HTTPTypes
import OpenAPIRuntime
import OTel
public import ServiceLifecycle
import Tracing

enum LocalTracingError: Error {
    case invalidCollectorHost
}

func localCollectorEndpoint(host: String) throws -> String {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { throw LocalTracingError.invalidCollectorHost }
    let octets = parts.compactMap { UInt8($0) }
    guard octets.count == 4, octets.map(String.init).joined(separator: ".") == host else {
        throw LocalTracingError.invalidCollectorHost
    }
    switch (octets[0], octets[1]) {
    case (10, _), (172, 16...31), (192, 168):
        break
    case (127, 0) where host == "127.0.0.1":
        break
    default:
        throw LocalTracingError.invalidCollectorHost
    }
    return "http://\(host):4318/v1/traces"
}

public func bootstrapLocalHTTPTracing(collectorHost: String?) throws -> (any Service)? {
    guard let collectorHost else { return nil }
    var configuration = OTel.Configuration.default
    configuration.serviceName = "sauna-api"
    configuration.logs.enabled = false
    configuration.metrics.enabled = false
    configuration.propagators = []
    configuration.traces.otlpExporter.endpoint = try localCollectorEndpoint(host: collectorHost)
    configuration.traces.otlpExporter.protocol = .httpProtobuf
    configuration.traces.otlpExporter.timeout = .seconds(2)
    configuration.traces.batchSpanProcessor.scheduleDelay = .seconds(1)
    configuration.traces.batchSpanProcessor.exportTimeout = .seconds(3)
    // Ambient OTel variables can change the destination and enable exporters for other signals.
    return try OTel.bootstrap(configuration: configuration, environment: [:])
}

struct LocalHTTPTracingMiddleware: ServerMiddleware {
    func intercept(
        _ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
        next: @concurrent @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // Generated operation IDs are fixed. Request paths, headers, and errors can contain user data.
        let span = startSpan(operationID, context: .topLevel, ofKind: .server)
        defer { span.end() }
        do {
            let response = try await next(request, body, metadata)
            span.attributes["http.response.status_code"] = response.0.status.code
            if response.0.status.code >= 500 { span.setStatus(.init(code: .error)) }
            return response
        } catch {
            span.setStatus(.init(code: .error))
            throw error
        }
    }
}
