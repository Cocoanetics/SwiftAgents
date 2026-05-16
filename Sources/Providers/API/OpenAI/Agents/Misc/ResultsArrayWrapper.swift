//
//  ResultsArrayWrapper.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 15.05.25.
//

import Foundation

struct ResultsArrayWrapper<T: Decodable>: Decodable
{
	let results: T
}
