// ntakker-cli/main.swift — see project-design.md §11.11, §14 (Phase K)
//
// Process entrypoint. We delegate to `AsyncParsableCommand.main()` on
// `RootCommand` so the parser correctly dispatches the async `run()`
// implementations on `StartCommand`, `StopCommand`, and
// `CheckPermissionsCommand`. We do NOT use `@main` on `RootCommand`
// because (a) the executable target ships a `main.swift` (canonical
// for SwiftPM `executableTarget`), and (b) keeping the dispatch
// explicit at the entrypoint makes the call hierarchy obvious.
//
// The `@MainActor` `Task` wrapper exists to give us an async context
// from which to call the async `main(_:)` overload — calling
// `RootCommand.main()` at file scope would otherwise resolve to the
// inherited synchronous `ParsableCommand.main()` overload (which
// silently skips the async `run()` methods on our subcommands).

import ArgumentParser
import Foundation

await asyncMainEntry()

@MainActor
private func asyncMainEntry() async {
    await RootCommand.main(nil)
}
