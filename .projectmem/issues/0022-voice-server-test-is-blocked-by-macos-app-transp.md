# #0022 Voice Server test is blocked by macOS App Transport Security for the HTTP Tailscale server URL.

- 2026-07-09T13:41:54Z `issue`: Voice Server test is blocked by macOS App Transport Security for the HTTP Tailscale server URL. [Soma.xcodeproj/project.pbxproj]
- 2026-07-09T13:45:48Z `attempt`: Added a main-app Info.plist with ATS exceptions for the Tailscale voice server and rebuilt/restarted Soma; authenticated health check returns 200. [Soma/Info.plist] (worked)
- 2026-07-09T13:45:53Z `fix`: Soma now permits the private HTTP Tailscale voice-server URL via a narrow ATS exception; rebuilt app runs and token health check returns 200. [Soma/Info.plist]
