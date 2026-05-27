import Foundation
import Providers

/// A type that can apply patch operations to create, update, or delete files.
public protocol AppliesPatches {
    func applyPatch(path: String, diff: String?, type: ApplyPatchCallOutput.OperationType) throws
}
