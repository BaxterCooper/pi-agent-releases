# Pi Agent Releases

Release artifacts and update manifests (`latest.json`) for the Pi Agent desktop app. Built and published by CI from the private `pi-agent` repository.

Install notes:
- **Windows:** the installer is unsigned; SmartScreen requires "More info" then "Run anyway".
- **macOS:** the app is ad-hoc signed; after first open is blocked, allow it under System Settings > Privacy & Security > "Open Anyway".
- **Linux:** `chmod +x` the AppImage, or install the `.deb`.

In-app updates verify minisign signatures and work on all platforms without OS code signing.
