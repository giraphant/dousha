//
//  File.swift
//  
//
//  Created by feichao on 2024/5/23.
//

import SwiftUI
import Combine

extension Task {
    public func store(in set: inout Set<AnyCancellable>) {
        set.insert(AnyCancellable(cancel))
    }
    
    public func store(in set: inout AnyCancellable?) {
        set = AnyCancellable(cancel)
    }
}

extension Task where Failure == Never {
    func store(in set: inout Set<AnyCancellable>) {
        set.insert(AnyCancellable(cancel))
    }
}
