//
//  ServiceTier.swift
//  AgentCorp
//
//  Created by Oliver Drobnik on 24.04.25.
//

import Foundation

/// Specifies the latency tier to use for processing the request.
public enum ServiceTier: String, Codable, Sendable
{
    /// Automatically determine the service tier based on project settings.
    /// If the Project is Scale tier enabled, utilizes scale tier credits until exhausted.
    /// If the Project is not Scale tier enabled, uses the default service tier with lower uptime SLA.
    case auto
    
    /// Use the default service tier with lower uptime SLA and no latency guarantee.
    case `default`
    
    /// Use the Flex Processing service tier.
    case flex
} 