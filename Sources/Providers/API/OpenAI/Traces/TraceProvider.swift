import Foundation

private let tracingLogsEnabled = ProcessInfo.processInfo.environment["TRACE_LOGS"] != nil

/*
 The main trace provider that coordinates trace and span creation.
 
 This singleton class manages trace processors and controls the global tracing state.
 */
public final class TraceProvider {
    /* Shared instance of the trace provider */
    public static let shared = TraceProvider()
    
    /* Actor that manages the collection of trace processors */
    let processorsActor = ProcessorsActor()
    /* Flag indicating whether tracing is disabled */
    private var isDisabled = false
    
    /*
     Adds a trace processor to the collection of processors.
     
     - Parameter processor: The processor to add
     */
    public func addProcessor(_ processor: TracingProcessor) async {
        await processorsActor.addProcessor(processor)
    }
    
    /*
     Replaces all trace processors with the given ones.
     
     - Parameter newProcessors: The new processors to use
     */
    public func setProcessors(_ newProcessors: [TracingProcessor]) async {
        await processorsActor.setProcessors(newProcessors)
    }
    
    /*
     Sets whether tracing is disabled.
     
     - Parameter disabled: Whether tracing should be disabled
     */
    public func setDisabled(_ disabled: Bool) {
        isDisabled = disabled
    }
    
    /*
     Shuts down the trace provider and all processors.
     */
    public func shutdown() async {
        await processorsActor.notifyProcessors { await $0.shutdown() }
    }
}

/*
 Actor that manages the collection of trace processors.
 
 This actor provides thread-safe access to the collection of processors.
 */
actor ProcessorsActor {
    /* The collection of trace processors */
    private var processors: [TracingProcessor] = []
    
    /*
     Adds a trace processor to the collection.
     
     - Parameter processor: The processor to add
     */
    func addProcessor(_ processor: TracingProcessor) {
        processors.append(processor)
    }
    
    /*
     Replaces all trace processors with the given ones.
     
     - Parameter newProcessors: The new processors to use
     */
    func setProcessors(_ newProcessors: [TracingProcessor]) {
        processors = newProcessors
    }
    
    /*
     Executes an action on all processors.
     
     - Parameter action: The action to execute on each processor
     */
    func notifyProcessors(_ action: (TracingProcessor) async -> Void) async {
        for processor in processors {
            await action(processor)
        }
    }
	
	init()
	{
		if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
		{
			let openAI = OpenAI(apiKey: apiKey)
			processors = [BatchTraceProcessor(exporter: BackendSpanExporter(openAI: openAI))]
			if tracingLogsEnabled {
				NSLog("Started OpenAI Batch Trace Exporter")
			}
		}
		else
		{
			if tracingLogsEnabled {
				NSLog("No OPENAI_API_KEY environment variable found, falling back to console trace exporter")
			}
			processors = [BatchTraceProcessor(exporter: ConsoleTraceExporter())]
		}
	}
}
