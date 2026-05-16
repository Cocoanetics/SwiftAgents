//
//  Handoff.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 05.05.25.
//

import Foundation
import SwiftMCP

/**
 A protocol that exposes the common surface for agent handoffs.

 Conforming types represent a handoff to another agent, optionally with typed input.
 */
public protocol Handoff: Sendable {
    /** The type of input accepted by the handoff. */
    associatedtype Input: Sendable

    /** The agent to which the handoff is targeted. */
    var targetAgent: (any Agent)? { get }

    /** The tool name for the handoff. */
    var toolName: String { get }

    /** The tool description for the handoff. */
    var toolDescription: String { get }

    /** The async function to perform the handoff with the given input. */
    var perform: (Input) async throws -> Void { get }

    /** The type of input accepted by the handoff. */
    var inputType: Any.Type { get }
}

// MARK: - Default Implementations

extension Handoff {
    /**
     Returns a transfer message for the handoff, including the target agent's name.
     - Returns: A string representing the transfer message.
     */
    func getTransferMessage() -> String {
        let name = targetAgent?.name ?? "unknown"
        return "{'assistant': '\(name)'}"
    }

    /** The type of input accepted by the handoff. */
    public var inputType: Any.Type {
        Input.self
    }

    /**
     Wrapper that allows calling the perform function while avoiding the generic constraint.
     You cannot call perform on "any Handoff" because the compiler doesn't see the type.
     - Parameter input: The input value to pass to the perform function.
     */
    func callPerform(input: Any) async throws {
        guard let input = input as? Input else {
            fatalError("Invalid input type \(type(of: input)) for \(Self.self)")
        }
        try await perform(input)
    }
}
