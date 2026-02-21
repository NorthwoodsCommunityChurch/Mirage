# File Transfer Project

See global profile at `~/.claude/CLAUDE.md` for user preferences and working style.

---

## Project Overview

**Mirage** — macOS app that mounts SMB network shares as local Finder volumes using rclone as the backend. Provides smart local caching, offline file protection, and "Keep on this Mac" mode to download entire shares for offline use.

GitHub repo: `NorthwoodsCommunityChurch/avl-mirage`
Appcast: `appcast-mirage.xml`
Bundle ID: `com.mirage.app`

---

## Technical Stack

- **Language:** Swift 5.9 / SwiftUI
- **Build:** XcodeGen (`project.yml` → `Mirage.xcodeproj`)
- **Dependencies:** Sparkle 2.x (auto-updates), rclone (external binary, auto-installed)
- **Storage:** Keychain (SMB passwords), JSON (`~/Library/Application Support/MountCache/shares.json`), UserDefaults (settings)
- **Process model:** Non-sandboxed; spawns rclone as a long-running subprocess per mounted share
- **Mount mechanism:** rclone `nfsmount` command + NFS loopback on macOS

---

## Project-Specific Notes

- rclone is installed to `/usr/local/bin/rclone` on first launch (prompted via OnboardingView)
- Mount points are created at `/Volumes/{shareName}` using privileged osascript if needed
- Cache lives at `~/Library/Caches/MountCache/{shareId}/vfs/`
- rclone remote names are UUID-based (avoids special character issues in config)
- `ENABLE_HARDENED_RUNTIME: false` is intentional — required to spawn rclone subprocess
- After code changes: run `xcodegen` in the `Mirage/` directory, then rebuild in Xcode
