//
//  UTType+LinuxCompat.swift
//
//
//  Created by OpenAI Codex on 16.05.26.
//

#if !canImport(UniformTypeIdentifiers)
import Foundation

struct UTType: Hashable, Sendable {
    let preferredMIMEType: String?
    let preferredFilenameExtension: String?

    init?(filenameExtension: String) {
        let filenameExtension = Self.normalizedFilenameExtension(filenameExtension)
        guard !filenameExtension.isEmpty,
              let mimeType = Self.extensionToMimeType[filenameExtension] else {
            return nil
        }

        self.preferredMIMEType = mimeType
        self.preferredFilenameExtension = filenameExtension
    }

    init?(mimeType: String) {
        let mimeType = Self.normalizedMIMEType(mimeType)
        guard !mimeType.isEmpty,
              let filenameExtension = Self.mimeTypeToExtension[mimeType] else {
            return nil
        }

        self.preferredMIMEType = mimeType
        self.preferredFilenameExtension = filenameExtension
    }

    private static func normalizedFilenameExtension(_ filenameExtension: String) -> String {
        filenameExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix(".")
            .lowercased()
    }

    private static func normalizedMIMEType(_ mimeType: String) -> String {
        mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static let extensionToMimeType: [String: String] = [
        "aac": "audio/aac",
        "avi": "video/x-msvideo",
        "bmp": "image/bmp",
        "csv": "text/csv",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "gif": "image/gif",
        "gz": "application/gzip",
        "heic": "image/heic",
        "htm": "text/html",
        "html": "text/html",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "js": "text/javascript",
        "json": "application/json",
        "jsonl": "application/jsonl",
        "md": "text/markdown",
        "mov": "video/quicktime",
        "mp3": "audio/mpeg",
        "mp4": "video/mp4",
        "mpeg": "video/mpeg",
        "oga": "audio/ogg",
        "ogg": "audio/ogg",
        "ogv": "video/ogg",
        "pdf": "application/pdf",
        "png": "image/png",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "rtf": "application/rtf",
        "svg": "image/svg+xml",
        "tar": "application/x-tar",
        "text": "text/plain",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "tsv": "text/tab-separated-values",
        "txt": "text/plain",
        "wav": "audio/wav",
        "webp": "image/webp",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xml": "application/xml",
        "zip": "application/zip"
    ]

    private static let mimeTypeToExtension: [String: String] = [
        "application/gzip": "gz",
        "application/json": "json",
        "application/jsonl": "jsonl",
        "application/msword": "doc",
        "application/pdf": "pdf",
        "application/rtf": "rtf",
        "application/vnd.ms-excel": "xls",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/x-tar": "tar",
        "application/xml": "xml",
        "application/zip": "zip",
        "audio/aac": "aac",
        "audio/mpeg": "mp3",
        "audio/ogg": "ogg",
        "audio/wav": "wav",
        "image/bmp": "bmp",
        "image/gif": "gif",
        "image/heic": "heic",
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/svg+xml": "svg",
        "image/tiff": "tiff",
        "image/webp": "webp",
        "text/csv": "csv",
        "text/html": "html",
        "text/javascript": "js",
        "text/markdown": "md",
        "text/plain": "txt",
        "text/tab-separated-values": "tsv",
        "video/mp4": "mp4",
        "video/mpeg": "mpeg",
        "video/ogg": "ogv",
        "video/quicktime": "mov",
        "video/x-msvideo": "avi"
    ]
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        var result = self
        while result.first == prefix {
            result.removeFirst()
        }
        return result
    }
}
#endif
