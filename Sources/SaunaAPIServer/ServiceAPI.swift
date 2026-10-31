public import SaunaAPIContract
import SaunaAPIIdentity
public import PostgresNIO

public struct ServiceAPI: APIProtocol {
    // Public release identifiers only. Never derive these from environment or git metadata.
    public static let apiVersion = "1.0.0"
    public static let applicationVersion = "0.1.0"

    private let isAvailable: Bool
    let authenticationClient: PostgresClient?

    /// The availability override is dependency injection for tests, not a public route or environment switch.
    public init(isAvailable: Bool = true, authenticationClient: PostgresClient? = nil) {
        self.isAvailable = isAvailable
        self.authenticationClient = authenticationClient
    }

    public func getHealth(_ input: Operations.GetHealth.Input) async throws -> Operations.GetHealth.Output {
        guard isAvailable else { return .serviceUnavailable(unavailable) }
        return .ok(.init(body: .json(.init(status: .ok))))
    }

    public func getVersion(_ input: Operations.GetVersion.Input) async throws -> Operations.GetVersion.Output {
        guard isAvailable else { return .serviceUnavailable(unavailable) }
        return .ok(.init(body: .json(.init(apiVersion: Self.apiVersion, version: Self.applicationVersion))))
    }

    private var unavailable: Components.Responses.ServiceUnavailable {
        .init(body: .applicationProblemJson(.init(_type: .about_colon_blank, title: .serviceUnavailable, status: ._503)))
    }
}
