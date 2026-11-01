import CBOR
import Crypto
import Foundation
import HTTPTypes
import HummingbirdTesting
import PostgresNIO
import SaunaAPIDatabase
import Testing
@testable import SaunaAPIIdentity
@testable import SaunaAPIServer

private struct HTTPVirtualPasskey: Sendable {
  private let key = P256.Signing.PrivateKey()
  let id = authRandomBytes()
  var cose: Data {
    let bytes = Array(key.publicKey.x963Representation)
    return Data(CBOR.map([.unsignedInt(1): .unsignedInt(2), .unsignedInt(3): .negativeInt(6), .negativeInt(0): .unsignedInt(1), .negativeInt(1): .byteString(Array(bytes[1..<33])), .negativeInt(2): .byteString(Array(bytes[33..<65]))]).encode())
  }
  private func client(_ nonce: Data, type: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["type": type, "challenge": authEncode(nonce), "origin": "http://localhost:5173", "crossOrigin": false])
  }
  func assertion(_ nonce: Data, handle: Data) throws -> Data {
    let client = try client(nonce, type: "webauthn.get")
    let auth = Data(SHA256.hash(data: Data("localhost".utf8))) + Data([0x05, 0, 0, 0, 0])
    let signature = try key.signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation
    return try JSONSerialization.data(withJSONObject: ["id": authEncode(id), "rawId": authEncode(id), "type": "public-key", "clientExtensionResults": [:], "response": ["clientDataJSON": authEncode(client), "authenticatorData": authEncode(auth), "signature": authEncode(signature), "userHandle": authEncode(handle)]])
  }
  func registration(_ nonce: Data) throws -> Data {
    let client = try client(nonce, type: "webauthn.create")
    let auth = Data(SHA256.hash(data: Data("localhost".utf8))) + Data([0x45, 0, 0, 0, 0]) + Data(repeating: 0, count: 16) + Data([0, UInt8(id.count)]) + id + cose
    let attestation = Data(CBOR.map([.textString("fmt"): .textString("none"), .textString("authData"): .byteString(Array(auth)), .textString("attStmt"): .map([:])]).encode())
    return try JSONSerialization.data(withJSONObject: ["id": authEncode(id), "rawId": authEncode(id), "type": "public-key", "clientExtensionResults": [:], "response": ["clientDataJSON": authEncode(client), "attestationObject": authEncode(attestation)]])
  }
}
private struct HTTPManagementOptions: Decodable {
  struct Options: Decodable { let challenge: String }
  let challengeID: UUID
  let publicKey: Options
  var nonce: Data { get throws { try authDecode(publicKey.challenge) } }
  func finish(_ credential: Data) throws -> String {
    let bytes = try JSONSerialization.data(withJSONObject: ["challengeID": challengeID.uuidString, "credentialJSON": String(decoding: credential, as: UTF8.self)])
    return String(decoding: bytes, as: UTF8.self)
  }
}

private actor HTTPManagementRecords {
  private var values: [UUID] = []
  func add(_ id: UUID) { values.append(id) }
  var ids: [UUID] { values }
}

struct PasskeyManagementHTTPTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PGPASSWORD_FILE"] != nil, "Requires local PostgreSQL password file"))
  func realHTTPManagementRequiresSessionAndCSRFAndClearsCookieAfterChanges() async throws {
    var env = ProcessInfo.processInfo.environment
    env["PGDATABASE"] = "sauna_atlas_replay"
    let config = try LocalDatabaseConfiguration(environment: env)
    try await LocalDatabase.withClient(configuration: config, timeout: .seconds(25)) { pool in
      let userID = UUID(), handle = authRandomBytes(), first = HTTPVirtualPasskey(), second = HTTPVirtualPasskey()
      let records = HTTPManagementRecords()
      func cleanup() async throws {
        _ = try await pool.query("DELETE FROM public.passkey_management_intents WHERE user_id=\(userID)").collect()
        _ = try await pool.query("DELETE FROM public.auth_sessions WHERE user_id=\(userID)").collect()
        _ = try await pool.query("DELETE FROM public.passkey_credentials WHERE user_id=\(userID)").collect()
        _ = try await pool.query("DELETE FROM public.passkey_accounts WHERE user_id=\(userID)").collect()
        _ = try await pool.query("DELETE FROM public.users WHERE id=\(userID)").collect()
        for id in await records.ids { _ = try await pool.query("DELETE FROM public.webauthn_challenges WHERE id=\(id)").collect() }
      }
      do {
        _ = try await pool.query("INSERT INTO public.users(id) VALUES (\(userID))").collect()
        _ = try await pool.query("INSERT INTO public.passkey_accounts(user_id,user_handle) VALUES (\(userID),\(handle))").collect()
        _ = try await pool.query("INSERT INTO public.passkey_credentials(id,user_id,user_handle,public_key_cose,sign_count,backup_eligible,is_backed_up) VALUES (\(first.id),\(userID),\(handle),\(first.cose),0,false,false)").collect()
        let login = try PasskeyAuthService(client: pool, relyingParty: .customer)
        @Sendable func signedLogin(_ key: HTTPVirtualPasskey) async throws -> SessionGrant {
          let binding = PasskeyFlowBinding.generate()
          let options = try await login.beginAuthentication(binding: binding)
          await records.add(options.challengeID)
          let payload = try JSONDecoder().decode(HTTPManagementOptions.Options.self, from: options.optionsJSON)
          return try await login.finishAuthentication(challengeID: options.challengeID, binding: binding, credentialJSON: key.assertion(authDecode(payload.challenge), handle: handle))
        }
        let grant = try await signedLogin(first)
        let app = try makeApplication(configuration: .init(), api: .init(authenticationClient: pool))
        try await app.test(.live) { client in
          let sessionCookie = "__Host-sauna-customer-session=" + grant.token.encoded
          let headers: HTTPFields = [.origin: "http://localhost:5173", .cookie: sessionCookie, HTTPField.Name("X-Sauna-CSRF")!: grant.session.csrfToken, .contentType: "application/json"]
          try await client.execute(uri: "/auth/passkeys", method: .get, headers: [.origin: "http://localhost:5173"]) { response in
            #expect(response.status == .unauthorized)
            #expect(response.headers[.cacheControl] == "no-store")
          }
          try await client.execute(uri: "/auth/passkeys", method: .get, headers: headers) { response in
            #expect(response.status == .ok)
            let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: [[String: Any]]])
            let credentials = try #require(object["credentials"])
            #expect(credentials.count == 1)
            let fields = Set(credentials[0].keys)
            #expect(fields.isSubset(of: ["credentialID", "createdAtUnixSeconds", "lastUsedAtUnixSeconds", "isCurrentSessionCredential"]))
          }
          let paths = ["/auth/passkeys/addition/authorization/options", "/auth/passkeys/addition/authorization/finish", "/auth/passkeys/addition/finish", "/auth/passkeys/revocation/options", "/auth/passkeys/revocation/finish"]
          for path in paths {
            let value: [String: Any]
            if path.hasSuffix("/finish") { value = ["challengeID": UUID().uuidString, "credentialJSON": "{}"] }
            else if path.contains("revocation") { value = ["credentialID": authEncode(first.id)] }
            else { value = [:] }
            let validBody = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            try await client.execute(uri: path, method: .post, headers: [.origin: "http://localhost:5173", .cookie: sessionCookie, .contentType: "application/json"], body: .init(string: validBody)) { response in
              #expect(response.status == .badRequest)
              #expect(response.headers[.cacheControl] == "no-store")
            }
          }
          var badCSRF = headers
          badCSRF[HTTPField.Name("X-Sauna-CSRF")!] = "synthetic-private-marker"
          try await client.execute(uri: paths[0], method: .post, headers: badCSRF) { response in
            #expect(response.status == .unauthorized)
            let hidden = !String(decoding: response.body.readableBytesView, as: UTF8.self).contains("synthetic-private-marker")
            #expect(hidden)
          }
          var wrongOrigin = headers; wrongOrigin[.origin] = "http://attacker.invalid"
          try await client.execute(uri: paths[0], method: .post, headers: wrongOrigin) { response in #expect(response.status == .forbidden) }
          let stepUp = try await client.execute(uri: paths[0], method: .post, headers: headers) { response in
            #expect(response.status == .ok)
            return try JSONDecoder().decode(HTTPManagementOptions.self, from: Data(response.body.readableBytesView))
          }
          let creation = try await client.execute(uri: paths[1], method: .post, headers: headers,
            body: .init(string: stepUp.finish(first.assertion(stepUp.nonce, handle: handle)))) { response in
            #expect(response.status == .ok)
            return try JSONDecoder().decode(HTTPManagementOptions.self, from: Data(response.body.readableBytesView))
          }
          try await client.execute(uri: paths[2], method: .post, headers: headers,
            body: .init(string: creation.finish(second.registration(creation.nonce)))) { response in
            #expect(response.status == .noContent)
            let cleared = response.headers[.setCookie]?.contains("Max-Age=0") == true
            #expect(cleared)
          }
          try await client.execute(uri: "/auth/passkeys", method: .get, headers: headers) { response in #expect(response.status == .unauthorized) }
          let secondGrant = try await signedLogin(second)
          let fresh: HTTPFields = [.origin: "http://localhost:5173", .cookie: "__Host-sauna-customer-session=" + secondGrant.token.encoded, HTTPField.Name("X-Sauna-CSRF")!: secondGrant.session.csrfToken, .contentType: "application/json"]
          let target = String(decoding: try JSONSerialization.data(withJSONObject: ["credentialID": authEncode(first.id)]), as: UTF8.self)
          let removal = try await client.execute(uri: paths[3], method: .post, headers: fresh, body: .init(string: target)) { response in
            #expect(response.status == .ok)
            return try JSONDecoder().decode(HTTPManagementOptions.self, from: Data(response.body.readableBytesView))
          }
          try await client.execute(uri: paths[4], method: .post, headers: fresh,
            body: .init(string: removal.finish(second.assertion(removal.nonce, handle: handle)))) { response in
            #expect(response.status == .noContent)
            let cleared = response.headers[.setCookie]?.contains("Max-Age=0") == true
            #expect(cleared)
          }
        }
        try await cleanup()
      } catch { try await cleanup(); throw error }
    }
  }
}
