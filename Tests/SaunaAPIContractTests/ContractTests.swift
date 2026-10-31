import Foundation
import Testing

import SaunaAPIContract

@Test func generatedHealthPayloadPreservesPublicWireFormat() throws {
    let body = Data(#"{"status":"ok"}"#.utf8)
    let decoded = try JSONDecoder().decode(Components.Schemas.Health.self, from: body)
    #expect(decoded.status.rawValue == "ok")
    let encoded = try JSONEncoder().encode(decoded)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
    #expect(object == ["status": "ok"])
}

@Test func generatedVersionPayloadPreservesPublicWireFormat() throws {
    let body = Data(#"{"apiVersion":"1.0.0","version":"0.1.0"}"#.utf8)
    let decoded = try JSONDecoder().decode(Components.Schemas.Version.self, from: body)
    #expect(decoded.apiVersion == "1.0.0")
    #expect(decoded.version == "0.1.0")
    let encoded = try JSONEncoder().encode(decoded)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
    #expect(object == ["apiVersion": "1.0.0", "version": "0.1.0"])
}

@Test func generatedProblemPayloadPreservesPublicWireFormat() throws {
    let body = Data(#"{"type":"about:blank","title":"Service Unavailable","status":503}"#.utf8)
    let decoded = try JSONDecoder().decode(Components.Schemas.ServiceUnavailableProblem.self, from: body)
    #expect(decoded.status.rawValue == 503)
    let encoded = try JSONEncoder().encode(decoded)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["type", "title", "status"])
    #expect(object["type"] as? String == "about:blank")
    #expect(object["title"] as? String == "Service Unavailable")
    #expect(object["status"] as? Int == 503)
}

@Test func generatedHealthRejectsUnknownStatus() {
    let body = Data(#"{"status":"failed"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Components.Schemas.Health.self, from: body)
    }
}

@Test func generatedVersionRejectsMissingRequiredRelease() {
    let body = Data(#"{"apiVersion":"1.0.0"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Components.Schemas.Version.self, from: body)
    }
}
