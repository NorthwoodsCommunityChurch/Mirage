# File Transfer Project

See global profile at `~/.claude/CLAUDE.md` for user preferences and working style.

---

## Project Overview

**Mirage** — macOS app that mounts SMB network shares as local Finder volumes using rclone as the backend. Provides smart local caching, offline file protection, and "Keep on this Mac" mode to download entire shares for offline use.

GitHub repo: `NorthwoodsCommunityChurch/Mirage`
Appcast: `appcast-mirage.xml` (in `app-updates` repo)
Bundle ID: `com.mirage.app`
Current version: **1.0.4** (build 5)

---

## Technical Stack

- **Language:** Swift 5.9 / SwiftUI
- **Build:** XcodeGen (`project.yml` → `Mirage.xcodeproj`)
- **Dependencies:** Sparkle 2.x (auto-updates), rclone (external binary, auto-installed)
- **Storage:** Keychain (SMB passwords), JSON (`~/Library/Application Support/MountCache/shares.json`), UserDefaults (settings)
- **Process model:** Non-sandboxed; spawns rclone as a long-running subprocess per mounted share
- **Mount mechanism:** rclone `nfsmount` command + NFS loopback on macOS
- **Logging:** Activity log (`~/Library/Logs/MountCache/mirage-activity.log`), per-share rclone logs (`~/Library/Logs/MountCache/mountcache-{uuid}.log`)
- **Crash reporting:** Signal handler writes to `~/Library/Application Support/MountCache/crash-report.json`; on next launch, offers to open pre-filled GitHub issue

---

## Architecture

### Mount lifecycle
`disconnected` → `mounting` → `indexing` → `mounted`

After rclone's NFS mount is live, the app enters **indexing** state and spawns a background task that lists the root directory. This triggers rclone to fetch the SMB directory listing from the server. Once complete, status flips to `mounted`. A double-mount guard in `AppState.mount()` prevents race conditions.

### Cache warming ("Keep on this Mac")
Uses a separate `rclone copy` subprocess (not NFS reads) to download all files from the remote directly into the VFS cache directory. This bypasses the mount for ~15x faster transfers and doesn't block Finder browsing. Periodic re-sync catches new/changed files.

### Key managers
| Class | Role |
|-------|------|
| `AppState` | Central @MainActor coordinator — mounts, shares, UI state |
| `RcloneProcessManager` | Spawns/kills rclone subprocesses, tracks PIDs |
| `RcloneCommandBuilder` | Builds rclone CLI argument arrays |
| `CacheManager` | Tracks VFS cache size, eviction, offline markers |
| `CacheWarmer` | Runs `rclone copy` for Keep Local mode |
| `StatusMonitor` | Polls rclone process liveness via Combine timer |
| `ShareStore` | Persists share configs to JSON + Keychain |
| `AppLogger` | Rolling activity log (last ~1000 lines) |
| `CrashReporter` | Signal/exception handler + GitHub issue reporter |
| `SMBShareDetector` | Detects SMB share info from dragged Finder URLs |

### Add-folder workflow
Both the empty-state hub and the "+" button use drag-and-drop detection. The user drags a network folder from Finder, `SMBShareDetector` extracts the SMB host/share/subfolder info on a background thread, and the add-project sheet pre-fills with detected values. Manual entry is available as a fallback.

---

## Project-Specific Notes

- rclone is installed to `/usr/local/bin/rclone` on first launch (prompted via OnboardingView)
- Mount points default to `~/Volumes/{volumeName}` (configurable in settings)
- Cache lives at `~/Library/Caches/MountCache/{shareId}/vfs/` (or custom path per project)
- rclone remote names are UUID-based: `mountcache-{first8chars}` (avoids special character issues)
- `ENABLE_HARDENED_RUNTIME: false` is intentional — required to spawn rclone subprocess
- After code changes: run `xcodegen` in the `Mirage/` directory, then rebuild in Xcode
- SMBShareDetector runs on a background thread — never call it on main thread (causes freeze/crash on slow networks)

---

## Security

See [SECURITY.md](SECURITY.md) for the full security review. Key findings include osascript command injection in runPrivileged (FT-01, CRITICAL), SMB password exposure in process arguments (FT-02, HIGH), and GitHub token stored in UserDefaults (FT-04, HIGH).
