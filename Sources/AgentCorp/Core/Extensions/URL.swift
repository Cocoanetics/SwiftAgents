//
//  URL.swift
//
//
//  Created by Oliver Drobnik on 01.05.24.
//

import Foundation
import UniformTypeIdentifiers

extension URL 
{
	/// Determines the preferred MIME type for a file
	func mimeType() -> String 
	{
		let pathExtension = self.pathExtension
		
		if let utType = UTType(filenameExtension: pathExtension)
		{
			return utType.preferredMIMEType ?? "application/octet-stream"
		} 
		else
		{
			return "application/octet-stream"
		}
	}
}
