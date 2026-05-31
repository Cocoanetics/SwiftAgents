//
//  String+MIMEType.swift
//
//
//  Created by Oliver Drobnik on 31.05.26.
//

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public extension String {
    /// The preferred filename extension (without a leading dot) for this string
    /// interpreted as a MIME type, e.g. `"image/png"` → `"png"`.
    ///
    /// `UTType` resolves through `UniformTypeIdentifiers` on Apple platforms and
    /// through the homegrown shim in
    /// `Providers/Support/UTType+LinuxCompat.swift` everywhere else, so the
    /// behaviour is identical across platforms — no per-call-site gating needed.
    /// Returns `nil` for an unrecognized type.
    func preferredFilenameExtension() -> String? {
        UTType(mimeType: self)?.preferredFilenameExtension
    }
}
