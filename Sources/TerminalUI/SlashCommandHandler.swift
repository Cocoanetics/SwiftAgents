//
//  SlashCommandHandler.swift
//
//
//  Created by Oliver Drobnik on 24.04.24.
//

import Foundation

/// Type-erased command executable so we can store heterogeneous return types.
protocol AnyCommandExecutable {
    /// Executes the underlying command, discarding any return value.
    func executeErased() async throws
}

/// A struct representing a command block of code that can be executed.
public struct CommandExecutable<ReturnType>: AnyCommandExecutable {
	let block: () async throws -> ReturnType

	public init(block: @escaping () async throws -> ReturnType) {
		self.block = block
	}

	public func execute() async throws -> ReturnType {
		return try await block()
	}

    // Type-erased execution used by SlashCommandHandler
    func executeErased() async throws {
        _ = try await block()
    }
}

/// A struct for handling slash commands.
public class SlashCommandHandler {
	/// A dictionary to store registered slash commands and their associated blocks.
    private var commands: [String: any AnyCommandExecutable] = [:]

	/// Registers a new slash command with its associated block.
	///
	/// - Parameters:
	///   - slashCommand: The string representing the slash command.
	///   - block: The block of code to be executed when the command is triggered.
	public func register<ReturnType>(slashCommand: String, block: @escaping () async throws -> ReturnType = { }) {
		commands[slashCommand] = CommandExecutable(block: block)
	}

	/// Executes the specified slash command.
	///
	/// - Parameter slashCommand: The string representing the slash command to be executed.
	/// - Throws: An `UnknownCommandError` if the specified command is not registered.
	public func execute(slashCommand: String) async throws {
        guard let executable = commands[slashCommand] else {
            throw UnknownCommandError.unknownCommand(slashCommand)
        }
        try await executable.executeErased()
	}

	/// An error type that represents an unknown command.
	///
	/// This error is thrown when attempting to execute a command that is not registered.
	public enum UnknownCommandError: Error, LocalizedError {
		/// The unrecognized command.
		case unknownCommand(String)

		public var errorDescription: String? {
			switch self {
			case .unknownCommand(let command):
				return NSLocalizedString("Unknown command: \(command)", comment: "Unknown command error")
			}
		}
	}
}
