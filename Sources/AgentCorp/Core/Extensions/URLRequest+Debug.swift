//
//  URLRequest+Debug.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 14.06.23.
//

import Foundation

extension URLRequest
{
	public var debugDescription: String
	{
		var tmpStr = ""

		if let httpMethod = httpMethod
		{
			tmpStr += httpMethod
		}

		if let url = url
		{
			if !tmpStr.isEmpty
			{
				tmpStr += " "
			}

			tmpStr += url.absoluteString
		}

		if !tmpStr.isEmpty
		{
			tmpStr += "\n\n"
		}

		if let httpBody = httpBody
		{
			do {
				if let jsonObject = try JSONSerialization.jsonObject(with: httpBody, options: []) as? [String: Any],
					let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
					let prettyPrintedString = String(data: prettyData, encoding: .utf8) {

					tmpStr += prettyPrintedString
				}
			} catch {
				print("Error parsing JSON: \(error)")
			}
		}

		return tmpStr
	}
}
