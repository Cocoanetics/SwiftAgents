//
//  Data+MimeType.swift
//
//
//  Created by Oliver Drobnik on 26.05.24.
//

import Foundation

extension Data 
{
	public func imageMimeType() -> String
	{
		var bytes = [UInt8](repeating: 0, count: 12)
		self.copyBytes(to: &bytes, count: 12)
		
		let bmp: [UInt8] = [0x42, 0x4D]
		let gif: [UInt8] = [0x47, 0x49, 0x46]
//		let swf: [UInt8] = [0x46, 0x57, 0x53]
//		let swc: [UInt8] = [0x43, 0x57, 0x53]
		let jpg: [UInt8] = [0xFF, 0xD8, 0xFF]
		let psd: [UInt8] = [0x38, 0x42, 0x50, 0x53]
		let iff: [UInt8] = [0x46, 0x4F, 0x52, 0x4D]
		let webp: [UInt8] = [0x52, 0x49, 0x46, 0x46]
		let ico: [UInt8] = [0x00, 0x00, 0x01, 0x00]
		let tifII: [UInt8] = [0x49, 0x49, 0x2A, 0x00]
		let tifMM: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A]
		let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
		let jp2: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
		
		if bytes.starts(with: bmp) {
			return "image/x-ms-bmp"
		} else if bytes.starts(with: gif) {
			return "image/gif"
		} else if bytes.starts(with: jpg) {
			return "image/jpeg"
		} else if bytes.starts(with: psd) {
			return "image/vnd.adobe.photoshop"
		} else if bytes.starts(with: iff) {
			return "image/iff"
		} else if bytes.starts(with: webp) {
			return "image/webp"
		} else if bytes.starts(with: ico) {
			return "image/vnd.microsoft.icon"
		} else if bytes.starts(with: tifII) || bytes.starts(with: tifMM) {
			return "image/tiff"
		} else if bytes.starts(with: png) {
			return "image/png"
		} else if bytes.starts(with: jp2) {
			return "image/jp2"
		}
		
		return "application/octet-stream" // default type
	}
}
