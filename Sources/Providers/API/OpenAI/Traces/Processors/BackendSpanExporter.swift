//
//  BackendSpanExporter.swift
//  SwiftAgents
//
//  Created by Oliver Drobnik on 07.05.25.
//

import Foundation
import SwiftMCP

/**
  A wrapper that implements sending tracing spans to the OpenAI backend
 */
public actor BackendSpanExporter: TracingExporter {
    let openAI: OpenAI

    public init(openAI: OpenAI) {
        self.openAI = openAI
    }

    public nonisolated func export(_ items: [[String: JSONValue]]) async {
        do {
            try await openAI.ingestTraces(items)
        } catch {
            print(error)
        }
    }
}
