//
//  StreamEvent.swift
//
//
//  Created by Oliver Drobnik on 03.05.24.
//

import Foundation

/** Represents an event emitted when streaming data.

   - SeeAlso: [Assistant Stream Events API](https://platform.openai.com/docs/api-reference/assistants-streaming/events)
 */
public struct StreamEvent {
    /// The type of the event.
    let type: String

    /// The object associated with the event.
    let object: StreamEventObject
}

/// Represents the object associated with a streaming event.
public enum StreamEventObject {
    /// A thread object.
    case thread(Thread)

    /// A run object.
    case run(Run)

    /// A run step object.
    case runStep(RunStep)

    /// A run step object.
    case runStepDelta(RunStepDelta)

    /// A message object.
    case message(Message)

    /// A message delta object.
    case messageDelta(ThreadMessageDelta)

    /// An error object.
    case error(ErrorDetail)
}
