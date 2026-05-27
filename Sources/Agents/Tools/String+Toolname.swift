//
//  String+Toolname.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 20.05.25.
//

import Foundation
import Providers

extension String {
    /// Formats a string to be used as a tool name by:
    /// 1. Replacing spaces with underscores
    /// 2. Replacing non-alphanumeric characters with underscores
    /// 3. Converting to lowercase
    var formattedToolName: String {
        // Replace spaces with underscores
        let withSpacesReplaced = replacingOccurrences(of: " ", with: "_")

        // Replace non-alphanumeric characters with underscores
        let alphanumericOnly = withSpacesReplaced.replacingOccurrences(
            of: "[^a-zA-Z0-9]",
            with: "_",
            options: .regularExpression
        )

        // Convert to lowercase
        return alphanumericOnly.lowercased()
    }
}
