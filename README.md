# termu

`termu` is a native macOS multi-host terminal manager starter app.

<img width="1415" height="797" alt="image" src="https://github.com/user-attachments/assets/6d2a2161-38d5-47cd-a2a7-54460feae14a" />


The first build focuses on the product shell:

- host and group management
- local JSON configuration storage
- iCloud key-value configuration sync
- SSH command generation
- embedded SwiftTerm-rendered PTY-backed SSH sessions using `/usr/bin/ssh`
- saved username, password, host, port, identity file, tags, and notes per host
- one-click fallback launch into the system Terminal app

The embedded terminal view uses SwiftTerm for VT100/xterm rendering while termu keeps its own SSH session layer for command construction, PTY lifecycle, saved-password submission, connection state, and failure reporting.


## Build

```sh
swift build
```

## Package a macOS app

```sh
Scripts/build_app.sh
open build/termu.app
```

## iCloud sync

The code already uses `NSUbiquitousKeyValueStore` for small host configuration sync. Real cross-device iCloud sync requires a signed app build with the iCloud key-value entitlement in `Resources/Termu.entitlements`.

Saved host passwords are part of the current host configuration model. That is convenient for a personal tool, but it is not an encrypted vault yet.

For a local unsigned build, the app still saves to:

```text
~/Library/Application Support/termu/config.json
```

When a signing identity is available:

```sh
TERMU_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build_app.sh
```

## License

termu is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE)
and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
