// Copyright (C) 2022 Gwendal Roué
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

public final class OneShotChannel<T: Sendable>: @unchecked Sendable {
    // MARK: - Internal State

    private enum Value {
        case pending
        case success(T)
        case error(Error)
    }

    /// Final value or pending.
    private var value: Value

    /// Suspended waiters, keyed by id so a single waiter can be removed
    /// by `onCancel` without disturbing the others. Continuations are
    /// throwing so we can resume them with `CancellationError` directly.
    private var continuations: [UUID: CheckedContinuation<T, Error>] = [:]

    private let _lock = NSRecursiveLock()

    // MARK: - Creating a Channel

    public init(_ type: T.Type) {
        self.value = .pending
    }

    deinit {
        precondition(
            continuations.isEmpty,
            "OneShotChannel is deallocated while task is suspended waiting for a signal.")
    }

    // MARK: - Locking
    //
    // Swift concurrency is... unfinished. We really need to protect our inner
    // state across the calls to `withCheckedThrowingContinuation`. Unfortunately,
    // that method introduces a suspension point, so we need a lock. The compiler
    // complains about lock() in async contexts, so the helpers below mute the
    // warning by hiding the lock behind regular methods.
    private func lock() { _lock.lock() }
    private func unlock() { _lock.unlock() }

    public var isFinished: Bool {
        lock()
        defer { unlock() }
        if case .pending = value {
            return false
        } else {
            return true
        }
    }

    // MARK: - Waiting

    /// Suspend until `finish(_:)` or `finish(throwing:)` resolves the channel.
    ///
    /// **Cancellation**: if the calling Task is cancelled while suspended,
    /// this throws `CancellationError` immediately — the continuation is
    /// removed from the waiter set and resumed. This makes the channel
    /// composable with structured concurrency.
    public func wait() async throws -> T {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                lock()
                // If cancellation arrived before we registered (e.g. parent
                // Task was already cancelled when wait() was entered), the
                // onCancel handler may have fired and found nothing to resume.
                // Detect this race here and bail out.
                if Task.isCancelled {
                    unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                switch value {
                case .success(let v):
                    unlock()
                    cont.resume(returning: v)
                case .error(let e):
                    unlock()
                    cont.resume(throwing: e)
                case .pending:
                    continuations[id] = cont
                    unlock()
                }
            }
        } onCancel: {
            lock()
            let cont = continuations.removeValue(forKey: id)
            unlock()
            cont?.resume(throwing: CancellationError())
        }
    }

    // MARK: - Signaling

    /// Resolve the channel with a value. All current and future waiters
    /// receive `value`. Subsequent `finish` calls are ignored.
    public func finish(_ value: T) {
        lock()
        guard case .pending = self.value else {
            unlock()
            return
        }
        self.value = .success(value)
        let pending = continuations
        continuations.removeAll()
        unlock()
        for (_, cont) in pending {
            cont.resume(returning: value)
        }
    }

    /// Resolve the channel with an error. All current and future waiters
    /// see the error thrown. Subsequent `finish` calls are ignored.
    public func finish(throwing error: Error) {
        lock()
        guard case .pending = self.value else {
            unlock()
            return
        }
        self.value = .error(error)
        let pending = continuations
        continuations.removeAll()
        unlock()
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
    }
}

extension OneShotChannel<Void> {
    public convenience init() {
        self.init(Void.self)
    }
}
