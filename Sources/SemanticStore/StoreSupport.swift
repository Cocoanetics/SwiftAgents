//
//  StoreSupport.swift
//  SwiftAgents
//
//  Small helpers shared by the `SemanticStore` implementations.
//

import Foundation

/// Stable, non-cryptographic content hash (FNV-1a 64-bit) for change
/// detection — deterministic across processes, unlike Swift's `Hasher`.
func fnv1aHash(_ bytes: some Sequence<UInt8>) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(hash, radix: 16)
}

/// `filePath` made relative to `workspaceDir` when it lies underneath it,
/// unchanged otherwise — keeps stored paths (and citations) workspace-relative.
func relativePath(_ filePath: String, to workspaceDir: String?) -> String {
    guard var base = workspaceDir else { return filePath }
    if !base.hasSuffix("/") { base += "/" }
    return filePath.hasPrefix(base) ? String(filePath.dropFirst(base.count)) : filePath
}
