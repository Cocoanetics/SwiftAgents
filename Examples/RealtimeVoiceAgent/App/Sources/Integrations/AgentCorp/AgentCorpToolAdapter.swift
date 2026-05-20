#if canImport(AgentCorp)
import AgentCorp

enum AgentCorpToolAdapter {
    // TODO: Bridge LocalToolDefinition into AgentCorp's tool schema types once
    // AgentCorp exposes a Realtime-specific transport/event surface. For this
    // prototype the adapter boundary is kept local so the app remains buildable
    // without pulling AgentCorp's full package graph into the Xcode project.
}
#endif
