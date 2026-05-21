//
//  EKEventStore+async.swift
//  API.me
//
//  Created by Oliver Drobnik on 28.03.25.
//

import Foundation
import EventKit

// MARK: - EKEventStore Extension

extension EKEventStore {
	func fetchReminders(matching predicate: NSPredicate) async throws -> [EKReminder] {
		try await withCheckedThrowingContinuation { continuation in
			fetchReminders(matching: predicate) { fetchedReminders in
				continuation.resume(returning: fetchedReminders ?? [])
			}
		}
	}
}
