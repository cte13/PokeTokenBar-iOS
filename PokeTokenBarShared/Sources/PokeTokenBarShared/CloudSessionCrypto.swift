import CryptoKit
import Foundation

/// Reader side of the cloud-session wire format written by
/// `scripts/cloud-session-sync/ptb-cloud-sync.mjs` (a Claude Code hook running inside Claude Code
/// on the web).
///
/// The cloud container holds nothing secret: environment variables there are readable by every
/// session. Records are sealed to this device key pair's **public** key; only the Mac and iPhone
/// hold the private key. The channel and record names are hashes of fixed labels and the public
/// key, so both sides derive them independently.
///
/// Wire format: public-DB record `CloudUsage` { channel, updatedAt, payload }, where payload is
/// `E.pub(32) ‖ nonce(12) ‖ AES-256-GCM ciphertext ‖ tag(16)`, the key being
/// HKDF-SHA256(X25519(E, P), salt: E.pub ‖ P, info: "ptb-cloud-usage/seal/v2") for a fresh
/// ephemeral key E per record, over raw deflate (RFC 1951) of
/// `{"v":2,"rel":"<project>/<session>.jsonl","chunk":N,"jsonl":"<trimmed transcript lines>\n"}`.
/// The Node test prints the cross-language fixture that `CloudSessionCryptoTests` pins.
public struct CloudSessionCrypto: Sendable {
    /// The hook uploads Claude Code transcripts, so its entries count as this provider.
    public static let providerID = "claude_code"
    public static let recordType = "CloudUsage"
    static let sealInfo = Data("ptb-cloud-usage/seal/v2".utf8)

    public enum Failure: Error, Equatable {
        case badKey, badBox, badPayload, unsafePath
    }

    private let agreement: Curve25519.KeyAgreement.PrivateKey
    /// Raw 32-byte X25519 public key — what the cloud environment's `PTB_SYNC_PUBLIC_KEY` holds.
    public let publicKey: Data

    public init(privateKey: Data) throws {
        guard privateKey.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw Failure.badKey
        }
        self.agreement = key
        self.publicKey = key.publicKey.rawRepresentation
    }

    /// The stored form: base64 of the 32-byte private key (surrounding whitespace ignored).
    public init(base64PrivateKey: String) throws {
        guard let data = Data(base64Encoded: base64PrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.badKey
        }
        try self.init(privateKey: data)
    }

    /// A fresh private key in the stored form.
    public static func generatePrivateKey() -> String {
        Curve25519.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
    }

    public var publicKeyBase64: String { publicKey.base64EncodedString() }

    /// Public-database records are readable by anyone holding the container's API token, so they
    /// are found by this opaque channel, never by anything that identifies the user.
    public var channel: String {
        String(Self.hex(Self.sha256(Data("ptb-cloud-usage/channel/v2".utf8) + publicKey)).prefix(32))
    }

    public func recordName(rel: String, chunk: Int) -> String {
        "cu_" + Self.hex(Self.sha256(Data("ptb-cloud-usage/record/v2|\(rel)|\(chunk)".utf8) + publicKey)).prefix(40)
    }

    /// Decrypts, inflates and validates one record payload.
    public func open(_ box: Data) throws -> CloudSessionPayload {
        let box = Data(box)   // re-base indices: a slice would make `prefix`/`dropFirst` offsets lie
        guard box.count > 32 + 12 + 16 else { throw Failure.badBox }
        let ephemeral = box.prefix(32)
        let plain: Data
        do {
            let key = try symmetricKey(ephemeralPublic: ephemeral)
            plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: box.dropFirst(32)), using: key)
        } catch {
            throw Failure.badBox
        }
        guard let json = try? (plain as NSData).decompressed(using: .zlib) as Data,
              let payload = try? JSONDecoder().decode(CloudSessionPayload.self, from: json),
              payload.v == 2, payload.chunk >= 0 else { throw Failure.badPayload }
        guard Self.isSafeRelativePath(payload.rel) else { throw Failure.unsafePath }
        return payload
    }

    /// Writer side, for tests and fixtures — production records are sealed by the Node hook.
    public func seal(_ payload: CloudSessionPayload,
                     ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
                     nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        let deflated = try (json as NSData).compressed(using: .zlib) as Data
        let shared = try ephemeral.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey))
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPublic + publicKey,
                                                 sharedInfo: Self.sealInfo, outputByteCount: 32)
        guard let combined = try AES.GCM.seal(deflated, using: key, nonce: nonce).combined else {
            throw Failure.badBox
        }
        return ephemeralPublic + combined
    }

    private func symmetricKey(ephemeralPublic: Data) throws -> SymmetricKey {
        let shared = try agreement.sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublic))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPublic + publicKey,
                                              sharedInfo: Self.sealInfo, outputByteCount: 32)
    }

    /// `rel` becomes a file path under the Mac's mirror folder, and it arrives from a record anyone
    /// with the container's API token could have written. Accept only what the hook produces:
    /// relative, no `..`/`.`/empty/hidden components (`jsonlFiles` skips hidden files, so a
    /// dot-prefixed component would silently never be counted), ending in `.jsonl`.
    public static func isSafeRelativePath(_ rel: String) -> Bool {
        guard !rel.hasPrefix("/"), rel.hasSuffix(".jsonl"), !rel.contains("\\"), !rel.contains("\0") else {
            return false
        }
        let parts = rel.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") }
    }

    private static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// One decrypted cloud-session record: a chunk of one transcript, trimmed to usage lines.
public struct CloudSessionPayload: Codable, Sendable, Equatable {
    public let v: Int
    /// `<project>/<session>.jsonl` or `<project>/<session>/subagents/<agent>.jsonl`.
    public let rel: String
    public let chunk: Int
    public let jsonl: String

    public init(v: Int = 2, rel: String, chunk: Int, jsonl: String) {
        self.v = v
        self.rel = rel
        self.chunk = chunk
        self.jsonl = jsonl
    }

    /// The usage entries in this chunk, parsed exactly like a local Claude transcript.
    public func entries(fmt: DateFormatter = UsageAggregation.localDayFormatter()) -> [UsageEntry] {
        jsonl.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            UsageAggregation.parseClaudeLine(String($0), fmt: fmt)
        }
    }
}
