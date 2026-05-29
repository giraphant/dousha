import Foundation

/// Tracks the WS close-handshake channels keyed by socket generation so a stale
/// socket's failure callback only wakes its own generation's waiter.
///
/// Without keying (a single shared channel), an overlapping stop/start/stop
/// cycle lets an older socket's trailing failure `finish()` the newer close's
/// channel — waking the wrong waiter (QUA-130). Each `register`/`signal`/
/// `remove` is scoped to one generation, so cross-generation wakeups can't
/// happen. All access is expected from a single isolation domain (the engine
/// actor); the type carries no internal locking of its own.
public struct GenerationCloseChannels {
    private var channels: [Int: OneShotChannel<Void>] = [:]

    public init() {}

    /// Create and store a fresh close channel for `generation`, returning it so
    /// the caller can await it directly.
    public mutating func register(_ generation: Int) -> OneShotChannel<Void> {
        let channel = OneShotChannel<Void>()
        channels[generation] = channel
        return channel
    }

    /// Wake only the waiter registered for `generation`. No-op if that
    /// generation has no (or no longer has a) channel.
    public func signal(_ generation: Int) {
        channels[generation]?.finish(())
    }

    /// Drop `generation`'s channel once its waiter has resolved.
    public mutating func remove(_ generation: Int) {
        channels[generation] = nil
    }
}
