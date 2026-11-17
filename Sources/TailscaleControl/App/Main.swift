import Foundation

/// Process entry point: `--self-test` runs the pure self-tests and exits; anything else starts the SwiftUI app
/// (`--close-self-test` opens the window and exits 0 shortly after).
@main
enum EntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTest.run())
        }
        if DemoMode.requestedOnCommandLine { DemoMode.enable() }
        TailscaleControlApp.main()
    }
}
