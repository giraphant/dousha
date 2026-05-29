import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Honor the persisted Dock-icon preference at launch; AppDelegate re-applies
// the same policy in applicationDidFinishLaunching.
app.setActivationPolicy(Preferences.shared.showDockIcon ? .regular : .accessory)
app.run()
