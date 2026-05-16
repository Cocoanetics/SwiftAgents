//
//  KeyedEncodingContainer+Extension.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 14.06.23.
//

import Foundation

extension KeyedEncodingContainer {

	mutating func encodeIfPresentOrNull(_ value: String?, forKey key: K) throws {
		if let v = value {
			try encode(v, forKey: key)
		} else {
			try encodeNil(forKey: key)
		}
	}
}
