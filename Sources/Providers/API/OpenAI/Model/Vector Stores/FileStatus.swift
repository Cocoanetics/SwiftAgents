//
//  FileStatus.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation

/**
 Represents the status of a file in a vector store.
 */
public enum FileStatus: String, Codable {
    /// Indicates that the file has expired.
    case expired

    /// Indicates that the file is currently in progress.
    case inProgress = "in_progress"

    /// Indicates that the file processing has been completed.
    case completed
}
