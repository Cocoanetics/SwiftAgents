import Foundation
import SwiftMCP

extension OutputItem {
    /// A function tool call.
    public struct FunctionCall: Codable, Sendable {
        /// The unique ID of the function tool call.
        public let id: String
        
        /// The unique ID for the function call, to be used when sending back results.
        public let callId: String
        
        /// The name of the function to run.
        public let name: String
        
        /// A JSON string of the arguments to pass to the function.
        public let arguments: String
        
        /// The status of the item.
        public let status: ResponseStatus?
        
        private enum CodingKeys: String, CodingKey {
            case id
            case callId
            case name
            case arguments
            case status
        }
		
		public func argumentsDictionary() throws -> [String: JSONValue]
		{
			guard !arguments.isEmpty,
				  let data = arguments.data(using: .utf8) else
			{
				return [:]
			}
			
			let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
			
			if let dict = jsonObject as? [String: Any]
			{
				return .init(jsonObject: dict)
			}
			else if let array =  jsonObject as? [[String: Any]]
			{
				var argumentsDict: [String: JSONValue] = [:]
				
				for item in array
				{
					if let name = item["name"] as? String,
						let value = item["value"]
					{
						argumentsDict[name] = .init(jsonObject: value)
					}
				}
				
				return argumentsDict
			}
			
			return [:]
		}
    }
} 
