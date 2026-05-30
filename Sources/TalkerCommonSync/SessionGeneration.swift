import Foundation

/// A monotonic session/socket/task counter with a uniform bump / capture /
/// isCurrent vocabulary. Carries NO synchronization of its own — the owner
/// provides isolation (a `Lock` for the 3-thread Apple recognizer case;
/// actor isolation for the WebSocket case), matching the three intentional
/// scopes (QUA-166). This type unifies the *vocabulary*; it deliberately does
/// NOT collapse those scopes into one global token.
public struct SessionGeneration: Sendable, Equatable {
    private var raw: UInt64 = 0
    public init() {}

    /// Advance to a new generation and return its token.
    public mutating func bump() -> Generation { raw &+= 1; return Generation(raw: raw) }
    /// Snapshot the live generation to compare against later.
    public var live: Generation { Generation(raw: raw) }
    /// Is `g` still the live generation?
    public func isCurrent(_ g: Generation) -> Bool { g.raw == raw }
}

/// An opaque token minted by `SessionGeneration`. `Hashable` so it can key the
/// WS close-handshake channels (`GenerationCloseChannels`). Only
/// `SessionGeneration` can mint one (`raw` is `fileprivate`).
public struct Generation: Sendable, Equatable, Hashable {
    fileprivate let raw: UInt64
}
