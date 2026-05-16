import Foundation
import Providers

extension CodingAgent: AppliesPatches {

	/// Apply a patch operation to create, update, or delete a file.
	/// - Parameter path: Path to the file (relative or absolute)
	/// - Parameter diff: The V4A diff to apply (nil for delete)
	/// - Parameter type: The operation type
    /// - returns: A string message signifying success
	func applyPatch(path: String, diff: String?, type: ApplyPatchCallOutput.OperationType) throws {
		let absolutePath = resolve(path)

		switch type {
		case .createFile:
			let dir = (absolutePath as NSString).deletingLastPathComponent
			try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
			let content = try applyDiff(input: "", diff: diff ?? "", mode: .create)
			try content.write(toFile: absolutePath, atomically: true, encoding: String.Encoding.utf8)

		case .updateFile:
			let original = try String(contentsOfFile: absolutePath, encoding: String.Encoding.utf8)
			let patched = try applyDiff(input: original, diff: diff ?? "")
			try patched.write(toFile: absolutePath, atomically: true, encoding: String.Encoding.utf8)

		case .deleteFile:
			try FileManager.default.removeItem(atPath: absolutePath)
		}
	}
}
