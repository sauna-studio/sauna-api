import Crypto
public import Foundation
import CBOR
public import WebAuthn

public enum PasskeyVerificationError: Error, Equatable, CustomStringConvertible {
    case invalidInput, rejected, unavailable
    public var description: String {
        switch self {
        case .invalidInput: "The passkey request is invalid."
        case .rejected: "The passkey verification failed."
        case .unavailable: "The passkey verification service is unavailable."
        }
    }
}

/// Persisted public credential material loaded by the server, never a client key.
public struct StoredPasskeyCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let credentialID: Data
    public let userHandle: Data
    public let publicKeyCOSE: Data
    public let signCount: UInt32
    public let backupEligible: Bool
    public init(credentialID: Data, userHandle: Data, publicKeyCOSE: Data, signCount: UInt32, backupEligible: Bool) {
        self.credentialID = credentialID
        self.userHandle = userHandle
        self.publicKeyCOSE = publicKeyCOSE
        self.signCount = signCount
        self.backupEligible = backupEligible
    }
    public var description: String { "StoredPasskeyCredential(<redacted>)" }
    public var debugDescription: String { description }
}

/// Only successful cryptographic verification constructs these result types.
public struct VerifiedPasskeyRegistration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let credentialID: Data
    public let publicKeyCOSE: Data
    public let signCount: UInt32
    public let backupEligible: Bool
    public let isBackedUp: Bool
    public var description: String { "VerifiedPasskeyRegistration(<redacted>)" }
    public var debugDescription: String { description }
}

public struct VerifiedPasskeyAssertion: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let credentialID: Data
    public let newSignCount: UInt32
    public let backupEligible: Bool
    public let isBackedUp: Bool
    public var description: String { "VerifiedPasskeyAssertion(<redacted>)" }
    public var debugDescription: String { description }
}

/// Test doubles live in test targets; no HTTP input is a verification result.
public protocol PasskeyVerifying: Sendable {
    func registrationOptions(challenge: Data, userHandle: Data) throws -> PublicKeyCredentialCreationOptions
    func authenticationOptions(challenge: Data) throws -> PublicKeyCredentialRequestOptions
    func verifyRegistration(credentialJSON: Data, challenge: Data, isCredentialAvailable: @escaping @Sendable (Data) async throws -> Bool) async throws -> VerifiedPasskeyRegistration
    func verifyAssertion(credentialJSON: Data, challenge: Data, storedCredential: StoredPasskeyCredential) throws -> VerifiedPasskeyAssertion
}

/// Local RP policy. Production RP/origins require a separate reviewed configuration.
public struct LivePasskeyVerifier: PasskeyVerifying {
    private let manager: WebAuthnManager
    private let origin: String
    public init(origin: String) throws {
        guard ["http://localhost:5173", "http://localhost:5174"].contains(origin) else {
            throw PasskeyVerificationError.invalidInput
        }
        self.origin = origin
        self.manager = WebAuthnManager(configuration: .init(relyingPartyID: "localhost", relyingPartyName: "Sauna Studio", relyingPartyOrigin: origin))
    }

    public func registrationOptions(challenge: Data, userHandle: Data) throws -> PublicKeyCredentialCreationOptions {
        guard challenge.count == 32, (1...64).contains(userHandle.count) else { throw PasskeyVerificationError.invalidInput }
        var options = manager.beginRegistration(
            user: .init(id: Array(userHandle), name: "Sauna account", displayName: "Sauna account"),
            publicKeyCredentialParameters: [.init(alg: .algES256)],
            authenticatorSelection: .init(residentKey: .required, userVerification: .required)
        )
        // The replacement is an existing CSPRNG nonce durably stored by our DB.
        // It is not caller-selected text; exact 32-byte shape is checked above.
        options.unsafeSetChallenge(Array(challenge))
        return options
    }

    public func authenticationOptions(challenge: Data) throws -> PublicKeyCredentialRequestOptions {
        guard challenge.count == 32 else { throw PasskeyVerificationError.invalidInput }
        var options = manager.beginAuthentication(userVerification: .required)
        options.unsafeSetChallenge(Array(challenge))
        return options
    }

    public func verifyRegistration(credentialJSON: Data, challenge: Data, isCredentialAvailable: @escaping @Sendable (Data) async throws -> Bool) async throws -> VerifiedPasskeyRegistration {
        do {
            let envelope = try credentialEnvelope(credentialJSON, challenge: challenge)
            let raw = try JSONDecoder().decode(RegistrationCredential.self, from: credentialJSON)
            try verifyClientData(Data(raw.attestationResponse.clientDataJSON), challenge: challenge, type: "webauthn.create")
            let attestation = try exactCBOR(Array(raw.attestationResponse.attestationObject))
            guard case .map(let object) = attestation,
                  object[.textString("fmt")] == .textString("none"),
                  object[.textString("attStmt")] == .map([:]),
                  case .byteString(let authData)? = object[.textString("authData")],
                  object.count == 3, authData.count > 55 else { throw PasskeyVerificationError.rejected }
            try validateFlags(authData[32], registration: true)
            let idLength = Int(authData[53]) * 256 + Int(authData[54])
            guard (1...1023).contains(idLength), authData.count > 55 + idLength,
                  Data(authData[55..<(55 + idLength)]) == envelope else { throw PasskeyVerificationError.rejected }
            let cose = Data(authData[(55 + idLength)...])
            try validateES256Key(cose)
            let verified = try await manager.finishRegistration(
                challenge: Array(challenge), credentialCreationData: raw, requireUserVerification: true,
                supportedPublicKeyAlgorithms: [.init(alg: .algES256)],
                confirmCredentialIDNotRegisteredYet: { _ in
                    do { return try await isCredentialAvailable(envelope) }
                    catch is CancellationError { throw CancellationError() }
                    catch { throw PasskeyVerificationError.unavailable }
                }
            )
            guard Data(verified.publicKey) == cose else { throw PasskeyVerificationError.rejected }
            return .init(credentialID: envelope, publicKeyCOSE: cose, signCount: verified.signCount, backupEligible: verified.backupEligible, isBackedUp: verified.isBackedUp)
        } catch { throw mapped(error) }
    }

    public func verifyAssertion(credentialJSON: Data, challenge: Data, storedCredential: StoredPasskeyCredential) throws -> VerifiedPasskeyAssertion {
        do {
            let id = try credentialEnvelope(credentialJSON, challenge: challenge)
            guard id == storedCredential.credentialID, (1...64).contains(storedCredential.userHandle.count) else { throw PasskeyVerificationError.rejected }
            try validateES256Key(storedCredential.publicKeyCOSE)
            let raw = try JSONDecoder().decode(AuthenticationCredential.self, from: credentialJSON)
            try verifyClientData(Data(raw.response.clientDataJSON), challenge: challenge, type: "webauthn.get")
            guard raw.response.authenticatorData.count == 37,
                  let userHandle = raw.response.userHandle,
                  Data(userHandle) == storedCredential.userHandle,
                  raw.response.attestationObject == nil else { throw PasskeyVerificationError.rejected }
            let flags = raw.response.authenticatorData[32]
            try validateFlags(flags, registration: false)
            guard (flags & 0x08 != 0) == storedCredential.backupEligible else { throw PasskeyVerificationError.rejected }
            let verified = try manager.finishAuthentication(
                credential: raw, expectedChallenge: Array(challenge), credentialPublicKey: Array(storedCredential.publicKeyCOSE),
                credentialCurrentSignCount: storedCredential.signCount, requireUserVerification: true
            )
            return .init(credentialID: id, newSignCount: verified.newSignCount, backupEligible: storedCredential.backupEligible, isBackedUp: verified.credentialBackedUp)
        } catch { throw mapped(error) }
    }

    private func credentialEnvelope(_ data: Data, challenge: Data) throws -> Data {
        guard challenge.count == 32, data.count <= 65_536 else { throw PasskeyVerificationError.invalidInput }
        try rejectDuplicateJSONProperties(data)
        let envelope = try JSONDecoder().decode(CredentialEnvelope.self, from: data)
        guard envelope.type == "public-key" else { throw PasskeyVerificationError.rejected }
        let id = try canonicalBase64URL(envelope.id)
        guard (1...1023).contains(id.count), id == (try canonicalBase64URL(envelope.rawId)) else { throw PasskeyVerificationError.rejected }
        return id
    }

    private func verifyClientData(_ data: Data, challenge: Data, type: String) throws {
        guard data.count <= 16_384 else { throw PasskeyVerificationError.rejected }
        try rejectDuplicateJSONProperties(data)
        let client = try JSONDecoder().decode(ClientData.self, from: data)
        guard client.type == type, client.origin == origin, try canonicalBase64URL(client.challenge) == challenge,
              client.crossOrigin != true else { throw PasskeyVerificationError.rejected }
    }

    private func mapped(_ error: any Error) -> any Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? PasskeyVerificationError { return error }
        return PasskeyVerificationError.rejected
    }
}

private struct CredentialEnvelope: Decodable {
    let id: String
    let rawId: String
    let type: String
    enum CodingKeys: String, CodingKey { case id, rawId, type, clientExtensionResults }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        rawId = try values.decode(String.self, forKey: .rawId)
        type = try values.decode(String.self, forKey: .type)
        if values.contains(.clientExtensionResults) {
            _ = try values.decode(EmptyExtensions.self, forKey: .clientExtensionResults)
        }
    }
}

private struct EmptyExtensions: Decodable {
    init(from decoder: any Decoder) throws {
        guard try decoder.container(keyedBy: AnyJSONKey.self).allKeys.isEmpty else { throw PasskeyVerificationError.rejected }
    }
}

private struct ClientData: Decodable {
    let type: String
    let challenge: String
    let origin: String
    let crossOrigin: Bool?
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: AnyJSONKey.self)
        // WebAuthn CollectedClientData requires tolerance of unknown keys.
        // Signed raw bytes remain unchanged; embedded/cross-origin flows are
        // deliberately unsupported by this local adapter.
        guard !values.contains(AnyJSONKey("topOrigin")) else { throw PasskeyVerificationError.rejected }
        type = try values.decode(String.self, forKey: AnyJSONKey("type"))
        challenge = try values.decode(String.self, forKey: AnyJSONKey("challenge"))
        origin = try values.decode(String.self, forKey: AnyJSONKey("origin"))
        let crossOriginKey = AnyJSONKey("crossOrigin")
        crossOrigin = values.contains(crossOriginKey) ? try values.decode(Bool.self, forKey: crossOriginKey) : nil
    }
}

private struct AnyJSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

func passkeyBase64URL(_ value: Data) -> String {
    value.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
}

private func canonicalBase64URL(_ string: String) throws -> Data {
    guard !string.isEmpty, string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }), string.count % 4 != 1,
          let data = Data(base64Encoded: string.replacing("-", with: "+").replacing("_", with: "/") + String(repeating: "=", count: (4 - string.count % 4) % 4)),
          passkeyBase64URL(data) == string else { throw PasskeyVerificationError.rejected }
    return data
}

private func validateFlags(_ flags: UInt8, registration: Bool) throws {
    guard flags & 0x05 == 0x05, flags & 0xa2 == 0,
          (flags & 0x40 != 0) == registration,
          flags & 0x10 == 0 || flags & 0x08 != 0 else { throw PasskeyVerificationError.rejected }
}

private func validateES256Key(_ bytes: Data) throws {
    guard !bytes.isEmpty, bytes.count <= 512, case .map(let key) = try exactCBOR(Array(bytes)), key.count == 5,
          key[.unsignedInt(1)] == .unsignedInt(2), key[.unsignedInt(3)] == .negativeInt(6),
          key[.negativeInt(0)] == .unsignedInt(1),
          case .byteString(let x)? = key[.negativeInt(1)], case .byteString(let y)? = key[.negativeInt(2)],
          x.count == 32, y.count == 32 else { throw PasskeyVerificationError.rejected }
    _ = try P256.Signing.PublicKey(x963Representation: Data([4] + x + y))
}

private func exactCBOR(_ bytes: [UInt8]) throws -> CBOR {
    try validatePasskeyCBORFraming(bytes)
    return try CBOR.decode(bytes, options: .init(maximumDepth: 16, rejectDuplicateMapKeys: true))
}
