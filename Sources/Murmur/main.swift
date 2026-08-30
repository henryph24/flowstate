import AppKit
import MurmurKit

setvbuf(stdout, nil, _IONBF, 0) // unbuffered logs when stdout is a pipe/file

let app = NSApplication.shared
// Initial policy; AppController switches to .regular at launch if the user
// enabled the Dock icon. Covers `swift run` dev loops too (no bundle plist).
app.setActivationPolicy(.accessory)
app.mainMenu = MainMenu.build()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
