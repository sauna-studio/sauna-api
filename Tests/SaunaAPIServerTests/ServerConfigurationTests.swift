import Testing
import SaunaAPIServer

@Test func defaultConfigurationBindsOnlyLoopback() throws {
    let configuration = try ServerConfiguration()
    #expect(configuration.port == 8080)
    #expect(configuration.bindHost == "127.0.0.1")
}

@Test(arguments: ["1", "8080", "65535"])
func validPortBoundaries(port: String) throws {
    #expect(try ServerConfiguration(port: port).port == Int(port))
}

@Test(arguments: ["", "0", "65536", "-1", "+8080", " 8080", "8080 ", "8080\n", "８０８０", "١٢٣", "80.5", "1e3", "99999999999999999999999999999999999"])
func invalidPortIsRejectedWithoutEchoingInput(port: String) {
    #expect(throws: ServerConfiguration.ConfigurationError.self) {
        try ServerConfiguration(port: port)
    }
}

@Test(arguments: ["127.0.0.1", "::1", "0.0.0.0"])
func bindAddressMustBeExplicitlyAllowed(host: String) throws {
    #expect(try ServerConfiguration(bindHost: host).bindHost == host)
}

@Test(arguments: ["", "localhost", "example.invalid", " 0.0.0.0", "0.0.0.0\n"])
func invalidBindHostIsRejected(host: String) {
    #expect(throws: ServerConfiguration.ConfigurationError.self) {
        try ServerConfiguration(bindHost: host)
    }
}
