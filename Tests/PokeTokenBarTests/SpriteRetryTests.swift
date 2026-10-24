import XCTest
import PokeTokenBarShared

/// The iPhone's sprite views retry temporary download failures (port of upstream #447).
/// Before this, a failed still sprite left a spinner and a failed GIF a still image until the
/// screen was rebuilt.
final class SpriteRetryTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _delays: [Duration] = []
        private var _attempts = 0
        var delays: [Duration] { lock.withLock { _delays } }
        var attempts: Int { lock.withLock { _attempts } }
        func wait(_ d: Duration) { lock.withLock { _delays.append(d) } }
        func attempt() -> Int { lock.withLock { _attempts += 1; return _attempts } }
    }

    func testRetriesTemporaryFailuresWithCappedBackoffUntilLoaded() async {
        let r = Recorder()
        let value = await SpriteRetry.load(waitBeforeRetry: { r.wait($0) }) { () -> SpriteFetchResult<String> in
            r.attempt() < 7 ? .failed : .loaded("sprite")
        }
        XCTAssertEqual(value, "sprite")
        XCTAssertEqual(r.attempts, 7)
        XCTAssertEqual(r.delays, [2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    }

    /// A 404 means the sprite doesn't exist; retrying would never succeed.
    func testNotFoundStopsWithoutRetrying() async {
        let r = Recorder()
        let value = await SpriteRetry.load(waitBeforeRetry: { r.wait($0) }) { () -> SpriteFetchResult<String> in
            _ = r.attempt()
            return .notFound
        }
        XCTAssertNil(value)
        XCTAssertEqual(r.attempts, 1)
        XCTAssertTrue(r.delays.isEmpty)
    }

    func testLoadedOnFirstAttemptNeverWaits() async {
        let r = Recorder()
        let value = await SpriteRetry.load(waitBeforeRetry: { r.wait($0) }) { () -> SpriteFetchResult<Int> in .loaded(1) }
        XCTAssertEqual(value, 1)
        XCTAssertTrue(r.delays.isEmpty)
    }

    /// The view's task owns the loop: when SwiftUI cancels it, the backoff ends.
    func testCancellationDuringBackoffStops() async {
        let r = Recorder()
        let task = Task {
            await SpriteRetry.load { () -> SpriteFetchResult<String> in
                _ = r.attempt()
                return .failed
            }
        }
        while r.attempts == 0 { await Task.yield() }
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
        XCTAssertEqual(r.attempts, 1, "the real 2 s sleep throws on cancel instead of retrying")
    }
}
