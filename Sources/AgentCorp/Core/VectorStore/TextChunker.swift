//
//  TextChunker.swift
//  Unit Tests
//
//  Created by Oliver Drobnik on 18.04.24.
//

import Foundation
import NaturalLanguage

class TextChunker
{
	let text: String
	
	var sections: [String]!

	var maxChunk = 500
	
	init(text: String)
	{
		self.text = text
		
		self.process()
	}
	
	func process()
	{
		var sections = [String]()
		
		var sectionText = ""
		
		text.enumerateMarkdownParagraphs { paragraph in
			
			if paragraph.isTitle && !sectionText.isEmpty || sectionText.count + paragraph.count > maxChunk
			{
				sections.append(sectionText.trimmingCharacters(in: .whitespacesAndNewlines))
				sectionText = ""
			}
			
			sectionText += paragraph
		}
		
		if !sectionText.isEmpty
		{
			sections.append(sectionText.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		
		self.sections = sections
	}
}


extension String
{
	public var isTitle: Bool
	{
		let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
		
		guard !trimmed.isEmpty else
		{
			return false
		}
		
		let lines = trimmed.components(separatedBy: "\n")
		
		if lines.count > 1
		{
			// A paragraph with multiple lines cannot be a title
			return false
		}
		
		if trimmed.hasPrefix("#")
		{
			return true
		}
		
		if trimmed.contains(".") || trimmed.contains("!") || trimmed.contains("?") || trimmed.contains(",") || trimmed.contains(";") || trimmed.contains(":")
		{
			return false
		}
		
		if trimmed.endsWithQuote
		{
			// it's quoted text
			return false
		}
		
		return true
	}
	
	public var endsWithQuote: Bool
	{
		return hasSuffix("\"") || hasSuffix("”") || hasSuffix("“")
	}
	
	public func enumerateMarkdownParagraphs(block: (String)->())
	{
		let tokenizer = NLTokenizer(unit: .paragraph)
		tokenizer.string = self
		
		var currentRange: Range<String.Index>!
		
		// enumerate paragraphs
		tokenizer.enumerateTokens(in: self.startIndex..<self.endIndex) { range, _ -> Bool in
			
			let part = String(self[range])
			
			if currentRange == nil
			{
				currentRange = range
			}
			else
			{
				// extend range to include this part
				currentRange = currentRange.lowerBound..<range.upperBound
			}
			
			if part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || range.upperBound == self.endIndex
			{
				// empty line, probably a paragraph break
				let paragraph = String(self[currentRange])
				block(paragraph)
				
				currentRange = nil
			}
			
			return true
		}
	}
	
	public func enumerateSentences(block: (String)->())
	{
		let tokenizer = NLTokenizer(unit: .sentence)
		tokenizer.string = self
		
		var currentRange: Range<String.Index>!
		
		// enumerate paragraphs
		tokenizer.enumerateTokens(in: self.startIndex..<self.endIndex) { range, _ -> Bool in
			
			let part = String(self[range])
			
			if currentRange == nil
			{
				currentRange = range
			}
			else
			{
				// extend range to include this part
				currentRange = currentRange.lowerBound..<range.upperBound
			}
			
			guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else
			{
				return true
			}
			
			let paragraph = String(self[currentRange])
			block(paragraph)
			
			currentRange = nil
			
			return true
		}
	}
}


