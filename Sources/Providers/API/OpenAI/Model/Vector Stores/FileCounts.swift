//
//  FileCounts.swift
//
//
//  Created by Oliver Drobnik on 02.05.24.
//

import Foundation

/**
 Represents counts of files in different processing states.
 */
public struct FileCounts: Codable, Sendable {
    /// The number of files currently in progress.
    public var inProgress: Int = 0

    /// The number of files that have been completed.
    public var completed: Int = 0

    /// The number of files that have failed processing.
    public var failed: Int = 0

    /// The number of files that have been cancelled.
    public var cancelled: Int = 0

    /// The total number of files.
    public var total: Int = 0
}
