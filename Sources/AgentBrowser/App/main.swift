import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)  // required even in .app bundle when launched via SPM executable
let delegate = AppDelegate()
app.delegate = delegate
app.run()
