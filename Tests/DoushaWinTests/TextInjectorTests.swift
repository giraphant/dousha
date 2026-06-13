#if os(Windows)
import XCTest
import WinSDK
@testable import DoushaWin

final class TextInjectorTests: XCTestCase {
    func testClipboardPasteInsertionTransfersUnicodeTextThenSendsFourPasteEvents() throws {
        let api = FakeTextInjectorWindowsAPI()

        TextInjector.type("你😀", owner: nil, api: api, log: { _ in })

        XCTAssertEqual(
            api.events,
            ["open", "empty", "allocate", "lock", "unlock", "setData", "close", "sendInput"]
        )
        XCTAssertEqual(api.clipboardCodeUnits, [0x4F60, 0xD83D, 0xDE00, 0])
        XCTAssertTrue(api.didTransferOwnership)
        XCTAssertFalse(api.didFreeMemory)

        let inputs = try XCTUnwrap(api.sentInputBatches.first)
        XCTAssertEqual(inputs.count, 4)
        XCTAssertEqual(inputs.map { $0.type }, Array(repeating: DWORD(INPUT_KEYBOARD), count: 4))
        XCTAssertEqual(inputs.map { $0.ki.wVk }, [WORD(0x11), WORD(0x56), WORD(0x56), WORD(0x11)])
        XCTAssertEqual(
            inputs.map { $0.ki.dwFlags },
            [DWORD(0), DWORD(0), DWORD(KEYEVENTF_KEYUP), DWORD(KEYEVENTF_KEYUP)]
        )
    }

    func testClipboardFailurePathsCleanUpWithoutSendingPaste() {
        let cases: [(FailurePoint, [String], Bool)] = [
            (.empty, ["open", "empty", "close"], false),
            (.allocate, ["open", "empty", "allocate", "close"], false),
            (.lock, ["open", "empty", "allocate", "lock", "free", "close"], true),
            (
                .setData,
                ["open", "empty", "allocate", "lock", "unlock", "setData", "free", "close"],
                true
            ),
        ]

        for (failure, expectedEvents, expectedFree) in cases {
            let api = FakeTextInjectorWindowsAPI()
            api.failurePoint = failure

            TextInjector.type("final transcript", owner: nil, api: api, log: { _ in })

            XCTAssertEqual(api.events, expectedEvents, "failure: \(failure)")
            XCTAssertEqual(api.didFreeMemory, expectedFree, "failure: \(failure)")
            XCTAssertFalse(api.didTransferOwnership, "failure: \(failure)")
            XCTAssertTrue(api.sentInputBatches.isEmpty, "failure: \(failure)")
        }
    }

    func testSuccessfulSetClipboardDataTransfersOwnershipWithoutFreeingMemory() {
        let api = FakeTextInjectorWindowsAPI()

        TextInjector.type("final transcript", owner: nil, api: api, log: { _ in })

        XCTAssertTrue(api.events.contains("unlock"))
        XCTAssertTrue(api.events.contains("close"))
        XCTAssertTrue(api.didTransferOwnership)
        XCTAssertFalse(api.didFreeMemory)
    }

    func testTextContainingNullIsRejectedBeforeOpeningClipboard() {
        let api = FakeTextInjectorWindowsAPI()
        var logs: [String] = []

        TextInjector.type("before\u{0000}after", owner: nil, api: api, log: { logs.append($0) })

        XCTAssertTrue(api.events.isEmpty)
        XCTAssertTrue(api.sentInputBatches.isEmpty)
        XCTAssertEqual(logs, ["[TextInjector] rejected text containing U+0000"])
    }

    func testClipboardOwnerIsPassedToOpenClipboard() {
        let api = FakeTextInjectorWindowsAPI()
        let owner = HWND(bitPattern: 0x1234)

        TextInjector.type("text", owner: owner, api: api, log: { _ in })

        XCTAssertEqual(api.openedClipboardOwner, owner)
    }

    func testOpenClipboardRetriesAfterInitialFailureThenPastes() {
        let api = FakeTextInjectorWindowsAPI()
        api.openClipboardResults = [false, true]

        TextInjector.type("text", owner: nil, api: api, log: { _ in })

        XCTAssertEqual(
            api.events,
            ["open", "sleep", "open", "empty", "allocate", "lock", "unlock", "setData", "close", "sendInput"]
        )
        XCTAssertEqual(api.sleepDurations, [10])
        XCTAssertEqual(api.sentInputBatches.count, 1)
    }

    func testOpenClipboardStopsAfterRetryLimitWithoutPasting() {
        let api = FakeTextInjectorWindowsAPI()
        api.failurePoint = .open
        var logs: [String] = []

        TextInjector.type("text", owner: nil, api: api, log: { logs.append($0) })

        XCTAssertEqual(
            api.events,
            ["open", "sleep", "open", "sleep", "open", "sleep", "open", "sleep", "open"]
        )
        XCTAssertEqual(api.sleepDurations, [10, 10, 10, 10])
        XCTAssertTrue(api.sentInputBatches.isEmpty)
        XCTAssertEqual(logs, ["[TextInjector] OpenClipboard failed (err=5)"])
    }

    func testZeroPasteEventsSentLogsFailureWithoutCleanupOrRetry() {
        let api = FakeTextInjectorWindowsAPI()
        api.sendResults = [(0, 5)]
        var logs: [String] = []

        TextInjector.type("text", owner: nil, api: api, log: { logs.append($0) })

        XCTAssertEqual(api.sentInputBatches.count, 1)
        XCTAssertEqual(api.sentInputBatches[0].count, 4)
        XCTAssertEqual(logs, ["[TextInjector] Ctrl+V SendInput sent 0/4 events (err=5)"])
    }

    func testPartialPasteDispatchSendsOnlyNecessaryKeyUpCleanup() throws {
        let cases: [(sent: UINT, expectedKeys: [WORD])] = [
            (1, [0x11]),
            (2, [0x56, 0x11]),
            (3, [0x11]),
        ]

        for testCase in cases {
            let api = FakeTextInjectorWindowsAPI()
            api.sendResults = [
                (testCase.sent, 5),
                (UINT(testCase.expectedKeys.count), 0),
            ]

            TextInjector.type("text", owner: nil, api: api, log: { _ in })

            XCTAssertEqual(api.sentInputBatches.count, 2, "sent prefix: \(testCase.sent)")
            let cleanup = api.sentInputBatches[1]
            XCTAssertEqual(cleanup.map { $0.ki.wVk }, testCase.expectedKeys)
            XCTAssertEqual(
                cleanup.map { $0.ki.dwFlags },
                Array(repeating: DWORD(KEYEVENTF_KEYUP), count: cleanup.count)
            )
        }
    }

    func testCleanupFailureLogsImmediateErrorWithoutRetrying() {
        let api = FakeTextInjectorWindowsAPI()
        api.sendResults = [(2, 5), (1, 87)]
        var logs: [String] = []

        TextInjector.type("text", owner: nil, api: api, log: { logs.append($0) })

        XCTAssertEqual(api.sentInputBatches.count, 2)
        XCTAssertEqual(
            logs,
            [
                "[TextInjector] Ctrl+V SendInput sent 2/4 events (err=5)",
                "[TextInjector] key-up cleanup sent 1/2 events (err=87)",
            ]
        )
    }
}

public func __allTests() -> [XCTestCaseEntry] {
    [
        testCase([
            ("testClipboardPasteInsertionTransfersUnicodeTextThenSendsFourPasteEvents", TextInjectorTests.testClipboardPasteInsertionTransfersUnicodeTextThenSendsFourPasteEvents),
            ("testClipboardFailurePathsCleanUpWithoutSendingPaste", TextInjectorTests.testClipboardFailurePathsCleanUpWithoutSendingPaste),
            ("testSuccessfulSetClipboardDataTransfersOwnershipWithoutFreeingMemory", TextInjectorTests.testSuccessfulSetClipboardDataTransfersOwnershipWithoutFreeingMemory),
            ("testTextContainingNullIsRejectedBeforeOpeningClipboard", TextInjectorTests.testTextContainingNullIsRejectedBeforeOpeningClipboard),
            ("testClipboardOwnerIsPassedToOpenClipboard", TextInjectorTests.testClipboardOwnerIsPassedToOpenClipboard),
            ("testOpenClipboardRetriesAfterInitialFailureThenPastes", TextInjectorTests.testOpenClipboardRetriesAfterInitialFailureThenPastes),
            ("testOpenClipboardStopsAfterRetryLimitWithoutPasting", TextInjectorTests.testOpenClipboardStopsAfterRetryLimitWithoutPasting),
            ("testZeroPasteEventsSentLogsFailureWithoutCleanupOrRetry", TextInjectorTests.testZeroPasteEventsSentLogsFailureWithoutCleanupOrRetry),
            ("testPartialPasteDispatchSendsOnlyNecessaryKeyUpCleanup", TextInjectorTests.testPartialPasteDispatchSendsOnlyNecessaryKeyUpCleanup),
            ("testCleanupFailureLogsImmediateErrorWithoutRetrying", TextInjectorTests.testCleanupFailureLogsImmediateErrorWithoutRetrying),
        ])
    ]
}

private enum FailurePoint: CustomStringConvertible, Equatable {
    case open
    case empty
    case allocate
    case lock
    case setData

    var description: String {
        switch self {
        case .open: "OpenClipboard"
        case .empty: "EmptyClipboard"
        case .allocate: "GlobalAlloc"
        case .lock: "GlobalLock"
        case .setData: "SetClipboardData"
        }
    }
}

private final class FakeTextInjectorWindowsAPI: TextInjectorWindowsAPI {
    var events: [String] = []
    var clipboardCodeUnits: [WCHAR] = []
    var sentInputBatches: [[INPUT]] = []
    var failurePoint: FailurePoint?
    var didFreeMemory = false
    var didTransferOwnership = false
    var sendResults: [(sent: UINT, error: DWORD)] = []
    var openedClipboardOwner: HWND?
    var openClipboardResults: [Bool] = []
    var sleepDurations: [DWORD] = []

    private var allocation: UnsafeMutableRawPointer?
    private var allocatedByteCount = 0

    deinit {
        allocation?.deallocate()
    }

    func openClipboard(owner: HWND?) -> Bool {
        events.append("open")
        openedClipboardOwner = owner
        if !openClipboardResults.isEmpty {
            return openClipboardResults.removeFirst()
        }
        return failurePoint != .open
    }

    func sleep(milliseconds: DWORD) {
        events.append("sleep")
        sleepDurations.append(milliseconds)
    }

    func closeClipboard() {
        events.append("close")
    }

    func emptyClipboard() -> Bool {
        events.append("empty")
        return failurePoint != .empty
    }

    func allocateMovableMemory(byteCount: Int) -> HGLOBAL? {
        events.append("allocate")
        guard failurePoint != .allocate else { return nil }
        allocatedByteCount = byteCount
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<WCHAR>.alignment
        )
        allocation = pointer
        return pointer
    }

    func lockMemory(_ memory: HGLOBAL) -> UnsafeMutableRawPointer? {
        events.append("lock")
        return failurePoint == .lock ? nil : memory
    }

    func unlockMemory(_ memory: HGLOBAL) {
        events.append("unlock")
    }

    func setUnicodeClipboardData(_ memory: HGLOBAL) -> Bool {
        events.append("setData")
        let count = allocatedByteCount / MemoryLayout<WCHAR>.size
        clipboardCodeUnits = Array(
            UnsafeBufferPointer(start: memory.assumingMemoryBound(to: WCHAR.self), count: count)
        )
        guard failurePoint != .setData else { return false }
        didTransferOwnership = true
        return true
    }

    func freeMemory(_ memory: HGLOBAL) {
        events.append("free")
        didFreeMemory = true
    }

    func sendInput(_ inputs: inout [INPUT]) -> (sent: UINT, error: DWORD) {
        events.append("sendInput")
        sentInputBatches.append(inputs)
        if sendResults.isEmpty {
            return (UINT(inputs.count), 0)
        }
        return sendResults.removeFirst()
    }

    func lastError() -> DWORD {
        5
    }
}
#endif
