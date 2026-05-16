//
//  BasicHandoff.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation

/**
 A basic handoff implementation for agents that do not require input.
 */
public struct BasicHandoff: Handoff {
	/** The type of input accepted by the handoff (Void). */
	public typealias Input = Void
	
	// MARK: - Properties
	/** The tool name for the handoff. */
	public let toolName: String
	/** The tool description for the handoff. */
	public let toolDescription: String
	/** The agent to which the handoff is targeted. */
	public weak var targetAgent: (any Agent)?
	/** The async function to perform the handoff. */
	public var perform: @Sendable (Input) async throws -> ()
	
	// MARK: - Initialization
	/**
	 Creates a new BasicHandoff.
	 - Parameters:
		- targetAgent: The agent to which the handoff is targeted.
		- toolNameOverride: Optional override for the tool name.
		- toolDescriptionOverride: Optional override for the tool description.
		- perform: Optional block to call when the handoff is performed.
	 */
	public init (
		targetAgent: any Agent,
		toolNameOverride: String? = nil,
		toolDescriptionOverride: String? = nil,
		perform: @Sendable @escaping (Input) -> Void = {(_: Input) in }
	) {
		// Set the target agent
		self.targetAgent = targetAgent
		
		// Set tool name and description
		self.toolName = toolNameOverride ?? "transfer_to_\(targetAgent.name.formattedToolName)"
		self.toolDescription = toolDescriptionOverride ?? targetAgent.defaultHandoffDescription
		
		// Set an optional block that gets called when the handoff is performed
		self.perform = perform
	}
}
