import Foundation
import JSONFoundation

/**
 Represents a single trace in the system.

 A trace is a logical unit of work that can contain multiple spans. It typically
 represents an entire operation or workflow in the system.
 */
public struct Trace: Identifiable, Codable, Sendable {
    /** Unique identifier for the trace */
    public let id: String
    /** Name of the workflow this trace represents */
    public let workflowName: String
    /** Optional group identifier to associate related traces */
    public let groupID: String?
    /** Optional metadata associated with the trace */
    public let metadata: [String: String]?

    /**
     Creates a new trace.

     - Parameter id: Unique identifier for the trace
     - Parameter workflowName: Name of the workflow this trace represents
     - Parameter groupID: Optional group identifier to associate related traces
     - Parameter metadata: Optional metadata associated with the trace
     */
    public init(id: String, workflowName: String, groupID: String? = nil, metadata: [String: String]? = nil) {
        self.id = id
        self.workflowName = workflowName
        self.groupID = groupID
        self.metadata = metadata
    }
}

// MARK: - Trace Extension

public extension Trace {
    /**
     Exports the trace as a dictionary.

     - Returns: A dictionary representation of the trace that can be serialized
     */
    func export() -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "object": JSONValue("trace"),
            "id": JSONValue(id),
            "workflow_name": JSONValue(workflowName)
        ]

        if let groupID {
            result["group_id"] = JSONValue(groupID)
        }

        if let metadata {
            result["metadata"] = JSONValue(metadata)
        }

        return result
    }
}
