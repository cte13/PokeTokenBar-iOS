import CryptoKit
import Foundation
import Testing
@testable import PokeTokenBarShared

/// Pins the Swift reader to the Node hook (`scripts/cloud-session-sync/ptb-cloud-sync.mjs`).
/// The fixture values are printed by the Node test "fixture values for the Swift test"; if that
/// output ever changes, update both sides together.
struct CloudSessionCryptoTests {
    static let privateKey = Data((1...32).map(UInt8.init))
    static let ephemeral = Data((0x41...0x60).map(UInt8.init))
    static let nonce = Data((0xA0...0xAB).map(UInt8.init))
    static let nodeBox = "ZLEBsdC+WocEvQePmJUAH8A+jp+VIvGI3RKNmEbUhGagoaKjpKWmp6ipqqu2k9tylicn5qm2wO8bXSifGwCeJTVQ4WnBjKfDteGjiLcw6aijBZAMneudCXBK5fysBKHctJ/TteRZmTKbFIF/n5OwEQMQ"

    @Test func derivesTheSamePublicKeyChannelAndRecordNameAsTheHook() throws {
        let crypto = try CloudSessionCrypto(privateKey: Self.privateKey)
        #expect(crypto.publicKeyBase64 == "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=")
        #expect(crypto.channel == "c98193ca7ae8b64ff8c3d5a3caccccb6")
        #expect(crypto.recordName(rel: "proj/s.jsonl", chunk: 2) == "cu_6109097f2472a133ebe2d9537cb04300f3442f96")
    }

    @Test func opensABoxSealedByTheHook() throws {
        let crypto = try CloudSessionCrypto(privateKey: Self.privateKey)
        let payload = try crypto.open(try #require(Data(base64Encoded: Self.nodeBox)))
        #expect(payload == CloudSessionPayload(rel: "proj/s.jsonl", chunk: 2, jsonl: "{\"a\":1}\n"))
    }

    /// With the fixture's ephemeral key and nonce, Swift writes the same header (ephemeral public
    /// key, nonce) as Node. The ciphertext cannot match byte for byte — the two JSON encoders
    /// order keys differently — so the cross-language proof is `opensABoxSealedByTheHook`.
    @Test func swiftSealsTheSameHeaderAsTheHook() throws {
        let crypto = try CloudSessionCrypto(privateKey: Self.privateKey)
        let box = try crypto.seal(CloudSessionPayload(rel: "proj/s.jsonl", chunk: 2, jsonl: "{\"a\":1}\n"),
                                  ephemeral: try .init(rawRepresentation: Self.ephemeral),
                                  nonce: try .init(data: Self.nonce))
        let opened = try crypto.open(box)
        #expect(opened.rel == "proj/s.jsonl")
        #expect(box.prefix(44) == (try #require(Data(base64Encoded: Self.nodeBox))).prefix(44))
    }

    @Test func swiftSealRoundTripsThroughOpen() throws {
        let crypto = try CloudSessionCrypto(privateKey: Self.privateKey)
        let payload = CloudSessionPayload(rel: "p/s/subagents/a.jsonl", chunk: 0, jsonl: "x\n")
        #expect(try crypto.open(try crypto.seal(payload)) == payload)
    }

    @Test func aDifferentPrivateKeyCannotOpenTheBox() throws {
        let other = try CloudSessionCrypto(privateKey: Data(repeating: 7, count: 32))
        #expect(throws: CloudSessionCrypto.Failure.badBox) {
            try other.open(try #require(Data(base64Encoded: Self.nodeBox)))
        }
        #expect(throws: CloudSessionCrypto.Failure.badBox) { try other.open(Data(count: 40)) }
    }

    @Test func rejectsKeysThatAreNot32Bytes() {
        #expect(throws: CloudSessionCrypto.Failure.badKey) { try CloudSessionCrypto(privateKey: Data(count: 16)) }
        #expect(throws: CloudSessionCrypto.Failure.badKey) { try CloudSessionCrypto(base64PrivateKey: "not base64!") }
        #expect(throws: Never.self) { try CloudSessionCrypto(base64PrivateKey: " \(Self.privateKey.base64EncodedString())\n") }
        #expect(Data(base64Encoded: CloudSessionCrypto.generatePrivateKey())?.count == 32)
    }

    /// `rel` becomes a path under the Mac's mirror folder and comes from a public record.
    @Test(arguments: [
        "/etc/x.jsonl", "../x.jsonl", "p/../../x.jsonl", "p/./x.jsonl", "p//x.jsonl", "p/.hidden.jsonl",
        ".p/x.jsonl", "p/x.json", "x.jsonl", "p\\x.jsonl", "p/x\0.jsonl",
    ])
    func unsafePathsAreRejected(rel: String) throws {
        #expect(!CloudSessionCrypto.isSafeRelativePath(rel))
        let crypto = try CloudSessionCrypto(privateKey: Self.privateKey)
        let box = try crypto.seal(CloudSessionPayload(rel: rel, chunk: 0, jsonl: ""))
        #expect(throws: CloudSessionCrypto.Failure.unsafePath) { try crypto.open(box) }
    }

    @Test(arguments: ["proj/s.jsonl", "-Users-me-repo/0f3a/subagents/agent-1.jsonl"])
    func hookPathShapesAreAccepted(rel: String) {
        #expect(CloudSessionCrypto.isSafeRelativePath(rel))
    }

    @Test func negativeChunkIsRejected() throws {
        let crypto = try CloudSessionCrypto(privateKey: Self.privateKey)
        let box = try crypto.seal(CloudSessionPayload(rel: "p/s.jsonl", chunk: -1, jsonl: ""))
        #expect(throws: CloudSessionCrypto.Failure.badPayload) { try crypto.open(box) }
    }

    @Test func payloadEntriesParseLikeALocalTranscript() {
        let line = #"{"type":"assistant","timestamp":"2026-09-27T10:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}"#
        let payload = CloudSessionPayload(rel: "p/s.jsonl", chunk: 0, jsonl: line + "\n{\"type\":\"user\"}\n")
        let entries = payload.entries()
        #expect(entries.count == 1)
        #expect(entries.first?.id == "msg_1|req_1")
        #expect(entries.first?.total == 100)
        #expect(entries.first?.model == "claude-opus-5-5")
    }
}
