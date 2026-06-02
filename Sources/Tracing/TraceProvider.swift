import Foundation

// `@unchecked Sendable`: the real shared state (the processor list) lives in
// `processorsActor`; `isDisabled` is a set-once startup flag.
/**
 The main trace provider that coordinates trace and span creation.

 This singleton class manages trace processors and controls the global tracing state.
 */
public final class TraceProvider: @unchecked Sendable {
    /** Shared instance of the trace provider */
    public static let shared = TraceProvider()

    /** Actor that manages the collection of trace processors */
    let processorsActor = ProcessorsActor()
    /** Flag indicating whether tracing is disabled */
    private var isDisabled = false

    /**
     Adds a trace processor to the collection of processors.

     - Parameter processor: The processor to add
     */
    public func addProcessor(_ processor: TracingProcessor) async {
        await processorsActor.addProcessor(processor)
    }

    /**
     Replaces all trace processors with the given ones.

     - Parameter newProcessors: The new processors to use
     */
    public func setProcessors(_ newProcessors: [TracingProcessor]) async {
        await processorsActor.setProcessors(newProcessors)
    }

    /**
     Sets whether tracing is disabled.

     - Parameter disabled: Whether tracing should be disabled
     */
    public func setDisabled(_ disabled: Bool) {
        isDisabled = disabled
    }

    /**
     Shuts down the trace provider and all processors.
     */
    public func shutdown() async {
        await processorsActor.notifyProcessors { await $0.shutdown() }
    }
}

/**
 Actor that manages the collection of trace processors.

 This actor provides thread-safe access to the collection of processors.
 */
actor ProcessorsActor {
    /** The collection of trace processors */
    private var processors: [TracingProcessor] = []

    /**
     Adds a trace processor to the collection.

     - Parameter processor: The processor to add
     */
    func addProcessor(_ processor: TracingProcessor) {
        processors.append(processor)
    }

    /**
     Replaces all trace processors with the given ones.

     - Parameter newProcessors: The new processors to use
     */
    func setProcessors(_ newProcessors: [TracingProcessor]) {
        processors = newProcessors
    }

    /**
     Executes an action on all processors.

     - Parameter action: The action to execute on each processor
     */
    func notifyProcessors(_ action: (TracingProcessor) async -> Void) async {
        for processor in processors {
            await action(processor)
        }
    }

    init() {
        // Default to no processors. Provider-specific exporters (e.g.
        // `OpenAITraceExporter`) live in their own targets and must be
        // registered explicitly at app startup. Callers that want stdout
        // tracing opt in via:
        //     await TraceProvider.shared.setProcessors([
        //         BatchTraceProcessor(exporter: ConsoleTraceExporter())
        //     ])
        processors = []
    }
}
