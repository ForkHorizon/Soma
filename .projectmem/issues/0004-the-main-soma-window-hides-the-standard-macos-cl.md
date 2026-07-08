# #0004 The main Soma window hides the standard macOS close, minimize, and fullscreen traffic-light controls.

- 2026-07-07T23:48:19Z `issue`: The main Soma window hides the standard macOS close, minimize, and fullscreen traffic-light controls. [Soma/ContentView.swift]
- 2026-07-07T23:50:04Z `attempt`: Removed the SwiftUI window-toolbar hiding modifier so the main macOS window can show standard traffic-light controls again. [Soma/ContentView.swift] (worked)
- 2026-07-07T23:50:08Z `fix`: Main Soma window no longer hides the window toolbar, so macOS close/minimize/fullscreen controls can render; verified with xcodebuild. [Soma/ContentView.swift]
