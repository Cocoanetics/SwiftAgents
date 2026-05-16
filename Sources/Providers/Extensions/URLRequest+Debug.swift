//
//  URLRequest+Debug.swift
//  OpenAI
//
//  Created by Oliver Drobnik on 14.06.23.
//

import Foundation

public extension URLRequest {
    var debugDescription: String {
        var tmpStr = ""

        if let httpMethod {
            tmpStr += httpMethod
        }

        if let url {
            if !tmpStr.isEmpty {
                tmpStr += " "
            }

            tmpStr += url.absoluteString
        }

        if !tmpStr.isEmpty {
            tmpStr += "\n\n"
        }

        if let httpBody {
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
