import Foundation
import Testing

enum TestResources {
    static func url(forResource name: String, withExtension ext: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: ext), "Missing resource \(name).\(ext)")
    }

    static func text(named name: String, withExtension ext: String) throws -> String {
        let url = try url(forResource: name, withExtension: ext)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
