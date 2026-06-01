//
//  URL.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import SwiftCross

extension URL {
    /// Determines the preferred MIME type for a file.
    ///
    /// `UTType` resolves through `UniformTypeIdentifiers` on Apple
    /// platforms and through SwiftCross's `UTType` shim everywhere
    /// else, so the behaviour is identical across platforms — no
    /// per-call-site gating needed.
    func mimeType() -> String {
        if let utType = UTType(filenameExtension: pathExtension) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
