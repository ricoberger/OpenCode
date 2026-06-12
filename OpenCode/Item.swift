//
//  Item.swift
//  OpenCode
//
//  Created by Rico Berger on 12.06.26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
