//
//  String+Reasoning.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 16.05.25.
//

import Foundation

extension String
{
	func extractReasoning() -> (reasoning: String?, content: String) {
		let pattern = "<think>([\\s\\S]*?)<\\/think>\\s*"
		if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
			let nsrange = NSRange(self.startIndex..<self.endIndex, in: self)
			if let match = regex.firstMatch(in: self, options: [], range: nsrange),
			   let reasoningRange = Range(match.range(at: 1), in: self) {
				let reasoning = String(self[reasoningRange]).trimmingCharacters(in: .whitespacesAndNewlines)
				// Remove the <think>...</think> block (and trailing whitespace) from the content
				let content = regex.stringByReplacingMatches(in: self, options: [], range: nsrange, withTemplate: "")
				return (reasoning, content)
			}
		}
		return (nil, self)
	}
}
