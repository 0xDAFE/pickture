### Build and Testing

Instead of running `xcodebuild` via command line, use the `xcode` MCP server tools (e.g., `BuildProject`, `RunAllTests`, `RunSomeTests`, `GetBuildLog`, etc.).

### SwiftUI Development

When writing, reviewing, or refactoring SwiftUI code (views, layouts, state management, animations, or view composition), always activate and consult the `swiftui-expert-skill` (`.agents/skills/swiftui-expert-skill/SKILL.md`) and verify the code against its Correctness Checklist.

### Swift Concurrency

When diagnosing Swift Concurrency issues, refactoring callback-based code to async/await, or working with tasks, actors, `@MainActor`, `Sendable`, data races, thread safety, or concurrency-related compiler warnings, always activate and consult the `swift-concurrency` skill (`.agents/skills/swift-concurrency/SKILL.md`).
