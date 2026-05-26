//
//  Runner+Workflow.swift
//  SwiftAgents
//

import Foundation

extension Runner {
    /// Builds the workflow name used on the trace dashboard. If the caller
    /// kept the default `RunConfig.workFlowName` ("Agent Workflow") we
    /// append the provider derived from the model spec so a glance at the
    /// dashboard tells which backend served the run. Names the caller
    /// explicitly set are passed through unchanged.
    static func workflowName(base: String, modelSpec: String) -> String {
        guard base == "Agent Workflow" else { return base }
        return "Agent Workflow (\(modelSpec.inferredProviderName))"
    }
}
