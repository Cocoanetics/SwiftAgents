import Foundation
import SwiftMCP

/** A processor that batches traces and spans before exporting them.
 
 Implementation notes:
 1. Uses async/await for thread safety
 2. Uses Timer with AsyncStream for scheduled exports
 3. Configurable batch sizes and export triggers
 4. Items stored in memory until exported
 */
public actor BatchTraceProcessor: TracingProcessor, @unchecked Sendable {
    // MARK: - Properties
    
    /** The exporter used to export batched traces and spans */
    private let exporter: TracingExporter
    
    /** Maximum number of items to store before dropping new ones */
    private let maxQueueSize: Int
    
    /** Maximum number of items to export in a single batch */
    private let maxBatchSize: Int
    
    /** Delay between scheduled export checks in seconds */
    private let scheduleDelay: TimeInterval
    
    /** Queue size ratio that triggers an immediate export */
    private let exportTriggerRatio: Double
    
    /** Calculated queue size that triggers an export */
    private let exportTriggerSize: Int
    
    /** Buffer of traces and spans waiting to be exported */
    private var queue: [Any] = []
    
    /** Flag indicating whether the processor has been shut down */
    private var isShutdown = false
    
    /** Task handling continuous export checks */
    private var exportTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    /** Creates a new batch trace processor with the specified configuration.
     
     - Parameters:
        - exporter: The exporter to use for exporting batched traces and spans
        - maxQueueSize: Maximum number of items to store before dropping (default: 8192)
        - maxBatchSize: Maximum number of items to export in a single batch (default: 128)
        - scheduleDelay: Delay between export checks in seconds (default: 5.0)
        - exportTriggerRatio: Queue size ratio that triggers export (default: 0.7)
     */
    public init(
        exporter: TracingExporter,
        maxQueueSize: Int = 8192,
        maxBatchSize: Int = 128,
        scheduleDelay: TimeInterval = 5.0,
        exportTriggerRatio: Double = 0.7
    ) {
        self.exporter = exporter
        self.maxQueueSize = maxQueueSize
        self.maxBatchSize = maxBatchSize
        self.scheduleDelay = scheduleDelay
        self.exportTriggerRatio = exportTriggerRatio
        self.exportTriggerSize = Int(Double(maxQueueSize) * exportTriggerRatio)
    }
    
    /** Starts the background export task. Must be called after initialization. */
    public func start() {
		
		precondition(!isShutdown, "Cannot start a already shutdown BatchTraceProcessor")
		
        self.exportTask = Task { [weak self] in
            while let self = self, await !self.isShutdown {
                await self.exportBatches(force: false)
                try? await Task.sleep(for: .seconds(self.scheduleDelay))
            }
        }
    }
	
	public func shutdown() async {
		
		guard !isShutdown else { return }
		
		isShutdown = true
		await exportBatches(force: true) // Export all remaining items
		exportTask?.cancel()             // Now cancel the background task
		exportTask = nil
	}
    
    // MARK: - TracingProcessor Implementation
    
    public func onTraceStart(_ trace: Trace) async {
        guard !isShutdown else { return }
		
		// start exporting if we didn't do so yet
		if exportTask == nil
		{
			start()
		}
		
        if queue.count < maxQueueSize {
            queue.append(trace)
            await checkExport()
        } else {
            print("Warning: Queue is full, dropping trace.")
        }
    }
    
    public func onTraceEnd(_ trace: Trace) async {
        // We handle traces via onTraceStart
		
		await exportBatches(force: true) // Export all remaining items
    }
    
    public func onSpanStart(_ span: TraceSpan) async {
        // We handle spans via onSpanEnd
    }
    
    public func onSpanEnd(_ span: TraceSpan) async {
		
        guard !isShutdown else { return }
        if queue.count < maxQueueSize {
            queue.append(span)
            await checkExport()
        } else {
            print("Warning: Queue is full, dropping span.")
        }
    }
    
    public func forceFlush() async {
        await exportBatches(force: true)
    }
    
    // MARK: - Private Methods
    
    /** Checks if we should trigger an export */
    private func checkExport() async {
        let queueSize = queue.count
        if queueSize >= exportTriggerSize {
            await exportBatches(force: false)
        }
    }
    
    /** Exports items in batches
     
     - Parameter force: If true, exports everything. Otherwise, exports up to maxBatchSize
     */
    private func exportBatches(force: Bool) async {
        while !queue.isEmpty {
            var batch: [[String: JSONValue]] = []
            
            // Take up to maxBatchSize items
            while !queue.isEmpty && (force || batch.count < maxBatchSize) {
                if let trace = queue.first as? Trace {
                    batch.append(trace.export())
                } else if let span = queue.first as? TraceSpan {
                    batch.append(span.export())
                }
                queue.removeFirst()
            }
            
            if !batch.isEmpty {
                await exporter.export(batch)
            }
            
            if !force && queue.count < exportTriggerSize {
                break
            }
        }
    }
} 
