import XCTest
@testable import Dousha

final class CancelKeyMonitorTests: XCTestCase {

    func testDisabledMonitor_startReturnsTrueAndNeverFires() {
        // A nil keycode means "cancel hotkey turned off". start() must succeed
        // without installing any CGEvent tap (we can't grant Accessibility
        // permission in unit tests, so a tap install would either fail or
        // require user interaction). The contract is: no tap installed →
        // shouldFire/onFire are never invoked.
        let shouldFireCalls = Counter()
        let fireCount = Counter()
        let monitor = CancelKeyMonitor(
            keyCode: nil,
            shouldFire: { shouldFireCalls.bump(); return true },
            onFire: { fireCount.bump() }
        )

        XCTAssertTrue(monitor.start(),
                      "disabled monitor must report start() success — there is no tap to fail to install")
        XCTAssertEqual(shouldFireCalls.value, 0)
        XCTAssertEqual(fireCount.value, 0)

        // stop() must be safe on a never-installed monitor.
        monitor.stop()
        XCTAssertEqual(fireCount.value, 0)
    }

    func testStop_isIdempotentOnDisabledMonitor() {
        let monitor = CancelKeyMonitor(
            keyCode: nil,
            shouldFire: { true },
            onFire: { }
        )
        // Multiple stop() calls without a matching start() must not crash.
        monitor.stop()
        monitor.stop()
    }
}

/// Thread-safe counter for tests — the @Sendable shouldFire/onFire closures
/// can't mutate captured `var Int`, but a reference to a final class with
/// internal NSLock state is safe to share.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int = 0

    func bump() { lock.lock(); n += 1; lock.unlock() }

    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
