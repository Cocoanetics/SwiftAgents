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
public struct FileCounts: Codable {
    /// The number of files currently in progress.
    var inProgress: Int = 0

    /// The number of files that have been completed.
    var completed: Int = 0

    /// The number of files that have failed processing.
    var failed: Int = 0

    /// The number of files that have been cancelled.
    var cancelled: Int = 0

    /// The total number of files.
    var total: Int = 0
}
