import Foundation

extension OutputItem {
    /// A web search tool call result.
    public struct WebSearchOutput: Codable, Sendable {
        /// The unique ID of the web search tool call.
        public let id: String

		/// The specific web action the model performed.
		public let action: Action?

        /// The status of the web search tool call.
        public let status: Response.ToolCallStatus?
    }

	public enum Action: Codable, Sendable {
		case search(Search)
		case openPage(OpenPage)
		case findInPage(FindInPage)

		private enum CodingKeys: String, CodingKey {
			case type
		}

		public init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let type = try container.decode(ActionType.self, forKey: .type)

			switch type {
			case .search:
				self = .search(try Search(from: decoder))
			case .openPage:
				self = .openPage(try OpenPage(from: decoder))
			case .findInPage:
				self = .findInPage(try FindInPage(from: decoder))
			}
		}

		public func encode(to encoder: Encoder) throws {
			switch self {
			case .search(let search):
				try search.encode(to: encoder)
			case .openPage(let openPage):
				try openPage.encode(to: encoder)
			case .findInPage(let findInPage):
				try findInPage.encode(to: encoder)
			}
		}
	}

	public enum ActionType: String, Codable, Sendable {
		case search
		case openPage = "open_page"
		case findInPage = "find_in_page"
	}

	public struct Search: Codable, Sendable {
		public let query: String?
		public let type: ActionType
		public let queries: [String]?
		public let sources: [Source]?

		public init(query: String? = nil, queries: [String]? = nil, sources: [Source]? = nil) {
			self.query = query
			self.type = .search
			self.queries = queries
			self.sources = sources
		}
	}

	public struct Source: Codable, Sendable {
		public let type: SourceType
		public let url: URL
	}

	public enum SourceType: String, Codable, Sendable {
		case url
	}

	public struct OpenPage: Codable, Sendable {
		public let type: ActionType
		public let url: URL?

		public init(url: URL? = nil) {
			self.type = .openPage
			self.url = url
		}
	}

	public struct FindInPage: Codable, Sendable {
		public let pattern: String
		public let type: ActionType
		public let url: URL

		public init(pattern: String, url: URL) {
			self.pattern = pattern
			self.type = .findInPage
			self.url = url
		}
	}
}
