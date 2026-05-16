//
//  KeyedEncodingContainer+Extension.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 14.06.23.
//

import Foundation

extension KeyedEncodingContainer {
    mutating func encodeIfPresentOrNull(_ value: String?, forKey key: K) throws {
        if let value = value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
