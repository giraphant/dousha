//
//  File.swift
//  
//
//  Created by feichao on 2024/5/23.
//

// Combine-only helper (the SwiftUI import was vestigial); Darwin-gated because
// Combine doesn't exist on Windows (QUA-209) and the sole caller is the app
// target's FloatingWindow.
#if canImport(Combine)
import Combine

extension Task {
    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(AnyCancellable(cancel))
    }
    
    public func store(in set: inout AnyCancellable?) {
        set = AnyCancellable(cancel)
    }
}
#endif
