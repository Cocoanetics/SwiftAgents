//
//  GitIgnore.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 04.04.26.
//

import Foundation

/// Parse a .gitignore file into directory and file patterns.
struct GitIgnore {
    var excludeDirs: [String] = []
    var excludeFiles: [String] = []

    init(workingDirectory: String) {
        let path = (workingDirectory as NSString).appendingPathComponent(".gitignore")
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("!") else { continue }

            if trimmed.hasSuffix("/") {
                let dir = String(trimmed.dropLast()).trimmingCharacters(in: .init(charactersIn: "/"))
                if !dir.isEmpty { excludeDirs.append(dir) }
            } else if !trimmed.contains("/") {
                excludeFiles.append(trimmed)
                // Patterns without a file extension could also be directories (e.g. "build", ".build")
                if !trimmed.contains(".") || trimmed.hasPrefix(".") {
                    excludeDirs.append(trimmed)
                }
            } else {
                let last = (trimmed as NSString).lastPathComponent
                if !last.contains(".") { excludeDirs.append(last) }
            }
        }

        if !excludeDirs.contains(".git") { excludeDirs.append(".git") }
    }
}
