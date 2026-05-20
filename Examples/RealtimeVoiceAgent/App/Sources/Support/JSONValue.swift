import Foundation
import SwiftMCP

// MARK: - Subscript access (used ~30 times across the realtime service)

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        dictionaryValue?[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
