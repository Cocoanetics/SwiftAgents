//
//  Tool+ApplyPatch.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 08.04.26.
//

import Foundation

public extension Tool {
	/// Whether the given model supports the apply_patch tool.
	/// Currently only OpenAI models gpt-5.4+ and o3+ support it.
	static func supportsApplyPatch(model: String) -> Bool {
		let lowered = model.lowercased()

		// Strip provider prefix (e.g. "openai/gpt-5.4" -> "gpt-5.4")
		let modelName: String
		if let slashIndex = lowered.firstIndex(of: "/") {
			modelName = String(lowered[lowered.index(after: slashIndex)...])
		} else {
			modelName = lowered
		}

		// o3 and o4 models support apply_patch
		if modelName.hasPrefix("o3") || modelName.hasPrefix("o4") {
			return true
		}

		// gpt-5.4 and higher support apply_patch
		if modelName.hasPrefix("gpt-") {
			let versionString = String(modelName.dropFirst(4)).prefix(while: { $0.isNumber || $0 == "." })
			let parts = versionString.split(separator: ".")
			if let major = parts.first.flatMap({ Int($0) }) {
				if major > 5 { return true }
				if major == 5 {
					let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
					return minor >= 4
				}
			}
		}

		return false
	}
}
