import AppKit
import SwiftUI

// SwiftPM executables have no Info.plist when run from .build, so make the
// process a regular foreground app before SwiftUI starts.
NSApplication.shared.setActivationPolicy(.regular)
MusicnoteApp.main()
