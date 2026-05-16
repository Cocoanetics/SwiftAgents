//
//  OllamaModelListResponse.swift
//
//
//  Created by Oliver Drobnik on 24.04.24.
//

import Foundation

/// Represents a list of models returned by the Ollama API.
public struct OllamaModelListResponse: Decodable {
    public var models: [OllamaModel]
}
