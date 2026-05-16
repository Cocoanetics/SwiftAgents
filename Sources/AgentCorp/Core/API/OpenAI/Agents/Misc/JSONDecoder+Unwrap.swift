//
//  JSONDecoder+Unwrap.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 18.05.25.
//

import Foundation

extension JSONDecoder
{
	/// Automatically unwraps an array type that is wrapped in ResultsArrayWrapper struct
	func decodeWithResultsUnwrap<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
		// Try direct decode
		if let direct = try? decode(T.self, from: data) {
			return direct
		}
		// Try wrapped decode
		if let wrapped = try? decode(ResultsArrayWrapper<T>.self, from: data) {
			return wrapped.results
		}
		return nil
	}
}
