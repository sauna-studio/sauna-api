import Crypto
import Foundation
import CBOR
import Testing
import WebAuthn
@testable import SaunaAPIIdentity

private let fixtureChallenge = Data(repeating: 0x51, count: 32)
private let fixtureHandle = Data(repeating: 0x61, count: 32)

/// Test-only authenticator. Every instance creates a new private key in memory;
/// no key is serialized to disk or attached to assertion failure diagnostics.
struct VirtualPasskey: Sendable, CustomStringConvertible {
    private let key = P256.Signing.PrivateKey()
    let id = authRandomBytes()
    var description: String { "VirtualPasskey(<redacted>)" }
    var cose: Data {
        let point = Array(key.publicKey.x963Representation)
        return Data(CBOR.map([
            .unsignedInt(1): .unsignedInt(2), .unsignedInt(3): .negativeInt(6),
            .negativeInt(0): .unsignedInt(1),
            .negativeInt(1): .byteString(Array(point[1..<33])),
            .negativeInt(2): .byteString(Array(point[33..<65])),
        ]).encode())
    }
    func authenticatorData(flags: UInt8, counter: UInt32, rp: String) -> Data {
        Data(SHA256.hash(data: Data(rp.utf8))) + Data([flags, UInt8(truncatingIfNeeded: counter >> 24), UInt8(truncatingIfNeeded: counter >> 16), UInt8(truncatingIfNeeded: counter >> 8), UInt8(truncatingIfNeeded: counter)])
    }
    func client(challenge: Data, origin: String, type: String, extras: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["type": type, "challenge": passkeyBase64URL(challenge), "origin": origin, "crossOrigin": false]
        for (key, value) in extras { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func registration(challenge: Data = fixtureChallenge, origin: String = "http://localhost:5173", flags: UInt8 = 0x45, rp: String = "localhost", idOverride: Data? = nil, rawIDOverride: Data? = nil, extras: [String: Any] = [:], extensions: [String: Any] = [:], clientOverride: Data? = nil) throws -> Data {
        let clientData = try clientOverride ?? client(challenge: challenge, origin: origin, type: "webauthn.create", extras: extras)
        let auth = authenticatorData(flags: flags, counter: 0, rp: rp) + Data(repeating: 0, count: 16) + Data([0, UInt8(id.count)]) + id + cose
        let attestation = Data(CBOR.map([.textString("fmt"): .textString("none"), .textString("authData"): .byteString(Array(auth)), .textString("attStmt"): .map([:])]).encode())
        return try JSONSerialization.data(withJSONObject: ["id": passkeyBase64URL(idOverride ?? id), "rawId": passkeyBase64URL(rawIDOverride ?? id), "type": "public-key", "clientExtensionResults": extensions, "response": ["clientDataJSON": passkeyBase64URL(clientData), "attestationObject": passkeyBase64URL(attestation)]])
    }
    func assertion(challenge: Data = fixtureChallenge, origin: String = "http://localhost:5173", flags: UInt8 = 0x05, rp: String = "localhost", counter: UInt32 = 0, handle: Data? = fixtureHandle, idOverride: Data? = nil, rawIDOverride: Data? = nil, extras: [String: Any] = [:], tamperSignature: Bool = false, clientOverride: Data? = nil) throws -> Data {
        let clientData = try clientOverride ?? client(challenge: challenge, origin: origin, type: "webauthn.get", extras: extras)
        let auth = authenticatorData(flags: flags, counter: counter, rp: rp)
        var signature = try key.signature(for: auth + Data(SHA256.hash(data: clientData))).derRepresentation
        if tamperSignature { signature[signature.count - 1] ^= 1 }
        var response: [String: Any] = ["clientDataJSON": passkeyBase64URL(clientData), "authenticatorData": passkeyBase64URL(auth), "signature": passkeyBase64URL(signature)]
        if let handle { response["userHandle"] = passkeyBase64URL(handle) }
        return try JSONSerialization.data(withJSONObject: ["id": passkeyBase64URL(idOverride ?? id), "rawId": passkeyBase64URL(rawIDOverride ?? id), "type": "public-key", "clientExtensionResults": [:], "response": response])
    }
    func stored(counter: UInt32 = 0, backupEligible: Bool = false) -> StoredPasskeyCredential {
        .init(credentialID: id, userHandle: fixtureHandle, publicKeyCOSE: cose, signCount: counter, backupEligible: backupEligible)
    }
}

private func expectRejected(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected fixed passkey rejection")
    } catch {
        let rejected = error as? PasskeyVerificationError == .rejected
        #expect(rejected)
    }
}

struct PasskeyVerifierTests {
    @Test func optionsRequireResidentCredentialAndUVWithES256Only() throws {
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let options = try verifier.registrationOptions(challenge: fixtureChallenge, userHandle: fixtureHandle)
        #expect(options.authenticatorSelection?.residentKey == .required)
        #expect(options.authenticatorSelection?.userVerification == .required)
        #expect(options.publicKeyCredentialParameters == [.init(alg: .algES256)])
        #expect(options.attestation == .none)
        let same = Data(options.challenge) == fixtureChallenge
        #expect(same)
        let login = try verifier.authenticationOptions(challenge: fixtureChallenge)
        #expect(login.userVerification == .required)
        #expect(login.allowCredentials == nil)
        #expect(throws: PasskeyVerificationError.invalidInput) { try LivePasskeyVerifier(origin: "http://attacker.invalid") }
        #expect(throws: PasskeyVerificationError.invalidInput) { try verifier.authenticationOptions(challenge: Data()) }
    }

    @Test func generatedP256RegistrationAndSignedAssertionSucceed() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let registration = try await verifier.verifyRegistration(credentialJSON: virtual.registration(), challenge: fixtureChallenge, isCredentialAvailable: { _ in true })
        let matches = registration.credentialID == virtual.id && registration.publicKeyCOSE == virtual.cose
        #expect(matches)
        #expect(registration.signCount == 0)
        #expect(!registration.backupEligible)
        #expect(String(describing: registration) == "VerifiedPasskeyRegistration(<redacted>)")
        let assertion = try verifier.verifyAssertion(credentialJSON: virtual.assertion(), challenge: fixtureChallenge, storedCredential: virtual.stored())
        let correctID = assertion.credentialID == virtual.id
        #expect(correctID)
        #expect(assertion.newSignCount == 0)
        #expect(String(reflecting: assertion) == "VerifiedPasskeyAssertion(<redacted>)")
    }

    @Test func unknownClientDataKeysRemainSignedAndAreTolerated() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let extra: [String: Any] = ["other_keys_can_be_added_here": "future client data", "future": ["nested": true]]
        let registration = try await verifier.verifyRegistration(credentialJSON: virtual.registration(extras: extra), challenge: fixtureChallenge) { _ in true }
        let stored = StoredPasskeyCredential(credentialID: virtual.id, userHandle: fixtureHandle, publicKeyCOSE: registration.publicKeyCOSE, signCount: 0, backupEligible: false)
        _ = try verifier.verifyAssertion(credentialJSON: virtual.assertion(extras: extra), challenge: fixtureChallenge, storedCredential: stored)
        #expect(throws: PasskeyVerificationError.rejected) {
            try verifier.verifyAssertion(credentialJSON: virtual.assertion(extras: extra, tamperSignature: true), challenge: fixtureChallenge, storedCredential: stored)
        }
    }

    @Test func registrationRejectsWrongOriginRPChallengeUVAndCredentialIdentities() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let payloads = try [virtual.registration(origin: "http://attacker.invalid"), virtual.registration(rp: "attacker.invalid"), virtual.registration(challenge: Data(repeating: 0x52, count: 32)), virtual.registration(flags: 0x41), virtual.registration(flags: 0x44), virtual.registration(flags: 0x55), virtual.registration(idOverride: Data([1, 2])), virtual.registration(idOverride: Data([1, 2]), rawIDOverride: Data([1, 2])), virtual.registration(extras: ["crossOrigin": true]), virtual.registration(extras: ["crossOrigin": NSNull()]), virtual.registration(extras: ["crossOrigin": "false"]), virtual.registration(extras: ["topOrigin": "http://attacker.invalid"]), virtual.registration(extensions: ["unknown": true])]
        for payload in payloads {
            await expectRejected { _ = try await verifier.verifyRegistration(credentialJSON: payload, challenge: fixtureChallenge, isCredentialAvailable: { _ in true }) }
        }
        await expectRejected { _ = try await verifier.verifyRegistration(credentialJSON: virtual.registration(), challenge: fixtureChallenge, isCredentialAvailable: { _ in false }) }
    }

    @Test func signedAssertionsRejectSignatureUVOriginRPHandleAndIdentityMismatches() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let payloads = try [virtual.assertion(tamperSignature: true), virtual.assertion(flags: 0x01), virtual.assertion(flags: 0x04), virtual.assertion(origin: "http://attacker.invalid"), virtual.assertion(rp: "attacker.invalid"), virtual.assertion(challenge: Data(repeating: 0x52, count: 32)), virtual.assertion(handle: nil), virtual.assertion(handle: Data([1, 2])), virtual.assertion(idOverride: Data([1, 2])), virtual.assertion(rawIDOverride: Data([1, 2])), virtual.assertion(extras: ["crossOrigin": true]), virtual.assertion(extras: ["crossOrigin": NSNull()]), virtual.assertion(extras: ["crossOrigin": "false"]), virtual.assertion(extras: ["topOrigin": "http://attacker.invalid"]), virtual.assertion(flags: 0x85)]
        for payload in payloads {
            await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: payload, challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        }
        let other = VirtualPasskey()
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: other.assertion(), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
    }

    @Test func knownAccountAllowsAbsentHandleWhileDiscoverableLoginRequiresIt() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let omitted = try virtual.assertion(handle: nil)
        var object = try #require(JSONSerialization.jsonObject(with: omitted) as? [String: Any])
        var response = try #require(object["response"] as? [String: Any])
        response["userHandle"] = NSNull(); object["response"] = response
        let null = try JSONSerialization.data(withJSONObject: object)
        for credential in [omitted, null] {
            let proof = try verifier.verifyAccountBoundAssertion(credentialJSON: credential, challenge: fixtureChallenge, storedCredential: virtual.stored())
            let sameID = proof.credentialID == virtual.id
            #expect(sameID)
            await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: credential, challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        }
        for handle in [Data(), Data(repeating: 0x71, count: 32)] {
            await expectRejected { _ = try verifier.verifyAccountBoundAssertion(credentialJSON: virtual.assertion(handle: handle), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        }
        for malformed in ["*not-base64url*" as Any, 123 as Any] {
            response["userHandle"] = malformed; object["response"] = response
            let credential = try JSONSerialization.data(withJSONObject: object)
            await expectRejected { _ = try verifier.verifyAccountBoundAssertion(credentialJSON: credential, challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        }
        await expectRejected { _ = try verifier.verifyAccountBoundAssertion(credentialJSON: virtual.assertion(handle: nil, tamperSignature: true), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        await expectRejected { _ = try verifier.verifyAccountBoundAssertion(credentialJSON: virtual.assertion(flags: 0x01, handle: nil), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
    }

    @Test func backupFlagsAndCounterPolicyAreVerified() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let synchronized = try verifier.verifyAssertion(credentialJSON: virtual.assertion(flags: 0x1d), challenge: fixtureChallenge, storedCredential: virtual.stored(backupEligible: true))
        #expect(synchronized.isBackedUp)
        #expect(synchronized.newSignCount == 0)
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: virtual.assertion(flags: 0x1d), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: virtual.assertion(flags: 0x15), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: virtual.assertion(counter: 4), challenge: fixtureChallenge, storedCredential: virtual.stored(counter: 4)) }
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: virtual.assertion(counter: 3), challenge: fixtureChallenge, storedCredential: virtual.stored(counter: 4)) }
        let next = try verifier.verifyAssertion(credentialJSON: virtual.assertion(counter: 5), challenge: fixtureChallenge, storedCredential: virtual.stored(counter: 4))
        #expect(next.newSignCount == 5)
    }

    @Test func JSONDuplicateKeyInspectionUsesDecodedPropertyNamesAndBoundedDepth() throws {
        for text in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, #"{"a":[{"b":1,"b":2}]}"#, String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18), #"{"a":}"#] {
            do { try rejectDuplicateJSONProperties(Data(text.utf8)); Issue.record("Expected malformed, duplicate or deep JSON rejection") }
            catch { /* fixed rejection; never print the source JSON */ }
        }
        try rejectDuplicateJSONProperties(Data(#"{"a":"brace } and quote \" and slash \\","b":[true,null,{"a":1}]}"#.utf8))
    }

    @Test func duplicateSecurityKeysAreRejectedEvenWithValidSignature() async throws {
        let virtual = VirtualPasskey()
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let client = Data((#"{"type":"webauthn.get","challenge":""# + passkeyBase64URL(fixtureChallenge) + #"","origin":"http://localhost:5173","crossOrigin":true,"crossOrigin":false}"#).utf8)
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: virtual.assertion(clientOverride: client), challenge: fixtureChallenge, storedCredential: virtual.stored()) }
        let malformed = Data(#"{"id":"a","id":"b","rawId":"a","type":"public-key"}"#.utf8)
        await expectRejected { _ = try verifier.verifyAssertion(credentialJSON: malformed, challenge: fixtureChallenge, storedCredential: virtual.stored()) }
    }
    @Test func duplicateCBORMapKeysAreRejectedBeforeUpstreamVerification() async throws {
        let virtual = VirtualPasskey()
        var envelope = try #require(JSONSerialization.jsonObject(with: virtual.registration()) as? [String: Any])
        var response = try #require(envelope["response"] as? [String: Any])
        let encoded = try #require(response["attestationObject"] as? String)
        var bytes = Array(try authDecode(encoded, maximum: 65_536))
        #expect(bytes.first == 0xa3)
        bytes[0] = 0xa4
        bytes += CBOR.textString("fmt").encode() + CBOR.textString("none").encode()
        response["attestationObject"] = authEncode(Data(bytes))
        envelope["response"] = response
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        await expectRejected {
            _ = try await verifier.verifyRegistration(credentialJSON: payload, challenge: fixtureChallenge) { _ in true }
        }
    }

    @Test func CBORFramingRejectsUnsupportedOrOversizedContainersBeforeDecoding() throws {
        let inputs: [[UInt8]] = [
            [], [0x81, 0], [0x9f, 0xff], [0xc0, 0], [0xf6],
            [0xbb] + Array(repeating: 0xff, count: 8),
            [0x5b] + Array(repeating: 0xff, count: 8),
            [0x59, 0x10, 0x00, 0], [0xa1, 0], [0xa0, 0],
            Array(repeating: [UInt8(0xa1), 0], count: 18).flatMap { $0 } + [0],
        ]
        for input in inputs {
            #expect(throws: PasskeyVerificationError.rejected) { try validatePasskeyCBORFraming(input) }
        }
        try validatePasskeyCBORFraming(Array(VirtualPasskey().cose))
        try validatePasskeyCBORFraming([0xa0])
    }

    @Test func availabilityErrorsAndCancellationAreFixedAndDistinct() async throws {
        enum SyntheticFailure: Error { case unavailable }
        let verifier = try LivePasskeyVerifier(origin: "http://localhost:5173")
        let payload = try VirtualPasskey().registration()
        do {
            _ = try await verifier.verifyRegistration(credentialJSON: payload, challenge: fixtureChallenge, isCredentialAvailable: { _ in throw SyntheticFailure.unavailable })
            Issue.record("Expected fixed storage availability failure")
        } catch {
            let unavailable = error as? PasskeyVerificationError == .unavailable
            #expect(unavailable)
            #expect(String(describing: error) == PasskeyVerificationError.unavailable.description)
        }
        do {
            _ = try await verifier.verifyRegistration(credentialJSON: payload, challenge: fixtureChallenge, isCredentialAvailable: { _ in throw CancellationError() })
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
    }

}
