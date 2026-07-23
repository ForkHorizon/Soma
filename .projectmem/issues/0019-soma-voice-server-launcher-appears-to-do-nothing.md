# #0019 Soma Voice Server launcher appears to do nothing because it exits after a notification and stale Launchpad entries still show old Soma builds.

- 2026-07-09T12:50:52Z `issue`: Soma Voice Server launcher appears to do nothing because it exits after a notification and stale Launchpad entries still show old Soma builds. [M1 /Applications/Soma Voice Server.app]
- 2026-07-09T12:53:19Z `attempt`: Updated the server launcher to show a real status dialog on open and removed stale Xcode Soma.app build products from local and M1 DerivedData. [M1 /Applications/Soma Voice Server.app] (worked)
- 2026-07-09T12:53:24Z `fix`: Soma Voice Server launcher now displays a status dialog on open, old generated Soma app bundles are removed, and server health/launcher smoke pass. [M1 /Applications/Soma Voice Server.app]
