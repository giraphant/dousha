//
//  File.swift
//
//
//  Created by feichao on 2024/5/23.
//

import Foundation

public class Lock<T>: @unchecked Sendable {
    private var data: T
    private let lock = NSLock()

    public init(_ data: T) {
        self.data = data
    }

    public func withLock<R>(_ block: (inout T) throws -> R) rethrows -> R {
        try lock.withLock {
            return try block(&data)
        }
    }

    public func value() -> T {
        return withLock { $0 }
    }

    public func setValue(_ value: T) {
        withLock { $0 = value }
    }
}
