import CryptoKit
import Foundation
import Testing
@testable import PokeTokenBarShared

/// Pins the Swift reader to the Node hook (`scripts/cloud-session-sync/ptb-cloud-sync.mjs`).
/// The fixture values are printed by the Node test "fixture values for the Swift test"; if that
/// output ever changes, update both sides together.
struct CloudSessionCryptoTests {
    static let secret = Data((1...32).map(UInt8.init))
    static let nodeBox = "oKGio6Slpqeoqaqr3+gleGVX1SySEWRalLGzyz0L/07zxidj+o6Hl/VVwIy6wrEL3exVAigHw0pe0xFfOE59T3L87MdnYl8//YZK0PqRJPUmmNydnhU="

    @Test func derivesTheSameChannelAndRecordNameAsTheHook() throws {
        let crypto = try CloudSessionCrypto(secret: Self.secret)
        #expect(crypto.channel == "eb4bca572ba7c3fab549b8d529a9f79a")
        #expect(crypto.recordName(rel: "proj/s.jsonl", chunk: 2) == "cu_5d5e8e9f412201ae5b00dcc97138f0aecb8317d1")
    }

    @Test func opensABoxSealedByTheHook() throws {
        let crypto = try CloudSessionCrypto(secret: Self.secret)
        let payload = try crypto.open(try #require(Data(base64Encoded: Self.nodeBox)))
        #expect(payload == CloudSessionPayload(rel: "proj/s.jsonl", chunk: 2, jsonl: "{\"a\":1}\n"))
    }

    @Test func swiftSealRoundTripsThroughOpen() throws {
        let crypto = try CloudSessionCrypto(secret: Self.secret)
        let payload = CloudSessionPayload(rel: "p/s/subagents/a.jsonl", chunk: 0, jsonl: "x\n")
        #expect(try crypto.open(try crypto.seal(payload)) == payload)
    }

    @Test func aDifferentSecretCannotOpenTheBox() throws {
        let other = try CloudSessionCrypto(secret: Data(repeating: 7, count: 32))
        #expect(throws: CloudSessionCrypto.Failure.badBox) {
            try other.open(try #require(Data(base64Encoded: Self.nodeBox)))
        }
    }

    @Test func rejectsSecretsThatAreNot32Bytes() {
        #expect(throws: CloudSessionCrypto.Failure.badSecret) { try CloudSessionCrypto(secret: Data(count: 16)) }
        #expect(throws: CloudSessionCrypto.Failure.badSecret) { try CloudSessionCrypto(base64Secret: "not base64!") }
        #expect(throws: Never.self) { try CloudSessionCrypto(base64Secret: " \(Self.secret.base64EncodedString())\n") }
        #expect(Data(base64Encoded: CloudSessionCrypto.generateSecret())?.count == 32)
    }

    /// `rel` becomes a path under the Mac's mirror folder and comes from a public record.
    @Test(arguments: [
        "/etc/x.jsonl", "../x.jsonl", "p/../../x.jsonl", "p/./x.jsonl", "p//x.jsonl", "p/.hidden.jsonl",
        ".p/x.jsonl", "p/x.json", "x.jsonl", "p\\x.jsonl", "p/x\0.jsonl",
    ])
    func unsafePathsAreRejected(rel: String) throws {
        #expect(!CloudSessionCrypto.isSafeRelativePath(rel))
        let crypto = try CloudSessionCrypto(secret: Self.secret)
        let box = try crypto.seal(CloudSessionPayload(rel: rel, chunk: 0, jsonl: ""))
        #expect(throws: CloudSessionCrypto.Failure.unsafePath) { try crypto.open(box) }
    }

    @Test(arguments: ["proj/s.jsonl", "-Users-me-repo/0f3a/subagents/agent-1.jsonl"])
    func hookPathShapesAreAccepted(rel: String) {
        #expect(CloudSessionCrypto.isSafeRelativePath(rel))
    }

    @Test func negativeChunkIsRejected() throws {
        let crypto = try CloudSessionCrypto(secret: Self.secret)
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
