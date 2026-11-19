import AppKit

// `Fosco redact <image> [output]` blurs one file and exits; with no arguments the menu bar app starts.
if CommandLine.arguments.dropFirst().first == "redact" {
    exit(runRedactCommand(Array(CommandLine.arguments.dropFirst(2))))
}

// `kill` and the install script end the app with SIGTERM; quit properly so a capture that is off
// the pasteboard while being read is given back first.
signal(SIGTERM, SIG_IGN)
let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSignal.setEventHandler { NSApplication.shared.terminate(nil) }
terminationSignal.resume()

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
