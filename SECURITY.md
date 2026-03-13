# Security Findings - Mirage (File Transfer)

**Review Date**: 2026-03-01
**Reviewer**: Alice (automated security review)
**Status**: Initial review

**Severity Summary**: 1 Critical, 3 High, 3 Medium, 2 Low

---

## Findings Table

| ID | Severity | Finding | File:Line | Status |
|----|----------|---------|-----------|--------|
| FT-01 | CRITICAL | osascript command injection in runPrivileged (unquoted paths) | RcloneInstaller.swift:161,147 | Open |
| FT-02 | HIGH | SMB password passed as command-line argument (visible in ps) | RcloneCommandBuilder.swift:40-46 | Open |
| FT-03 | HIGH | pkill with unsanitized remoteName allows process injection | RcloneProcessManager.swift:270-273 | Open |
| FT-04 | HIGH | GitHub API token stored in UserDefaults (plaintext) | CrashReporter.swift:47,73 | Open |
| FT-05 | MEDIUM | Crash report includes activity logs and app state (info disclosure) | CrashReporter.swift:168-246 | Open |
| FT-06 | MEDIUM | Activity log file permissions 0644 (world-readable) | AppLogger.swift:31 | Open |
| FT-07 | MEDIUM | Share config stored as unencrypted JSON | ShareStore.swift | Open |
| FT-08 | LOW | Redirect follower forwards auth headers to redirected hosts | CrashReporter.swift:413-433 | Open |
| FT-09 | LOW | HelperInstaller paths from bundle interpolated into osascript | (Note: paths POSIX-quoted - low risk) | Info |

---

## Detailed Findings

### FT-01: osascript command injection in runPrivileged (CRITICAL)

**File**: `RcloneInstaller.swift:161,147`

The `runPrivileged` method at line 200-210 embeds commands directly into an osascript `do shell script` invocation without escaping:

```swift
private func runPrivileged(_ command: String) async throws {
    let script = "do shell script \"\(command)\" with administrator privileges"
```

This is called with unquoted paths at line 161:
```swift
try await runPrivileged("cp \(extractedBinary.path) \(destPath)")
```

And at line 147:
```swift
try await runPrivileged("mkdir -p \(installDir)")
```

While the `installDir` is a constant (`/usr/local/bin`), the `extractedBinary.path` includes a UUID-named temp directory which is safe. However, the pattern is dangerous and could be exploited if paths with shell metacharacters are ever passed. Note: the version string IS validated with regex at line 91 (good), but the path interpolation itself is unprotected.

Contrast with `RcloneProcessManager.swift:291-293` which correctly POSIX-quotes the path:
```swift
let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
let script = "do shell script \"mkdir -p '\(escapedPath)'\" with administrator privileges"
```

**Impact**: Command injection with administrator privileges via crafted file paths.
**Remediation**: Apply the same POSIX-quoting pattern used in `createDirectoryPrivileged` to all `runPrivileged` calls.

---

### FT-02: SMB password passed as command-line argument (HIGH)

**File**: `RcloneCommandBuilder.swift:40-46`

The `createRemoteArguments` method passes the SMB password directly as a command-line argument:

```swift
func createRemoteArguments(..., password: String, ...) -> [String] {
    ["config", "create", name, "smb",
     "host=\(host)", "user=\(username)", "pass=\(password)", ...]
}
```

Command-line arguments are visible to all users via `ps aux` or `/proc/[pid]/cmdline`. While the password is also stored in the Keychain (good), it is briefly exposed in the process table during rclone config creation.

**Impact**: SMB credentials visible in process listing during config creation.
**Remediation**: Use rclone's `--config` stdin mode or environment variables to pass the password, or use `RCLONE_CONFIG_<REMOTE>_PASS` environment variable.

---

### FT-03: pkill with unsanitized remoteName (HIGH)

**File**: `RcloneProcessManager.swift:270-273`

The `killOrphanRclone` method passes `remoteName` directly to `pkill -f`:

```swift
private func killOrphanRclone(remoteName: String) async {
    _ = try? await Process.run(
        executableURL: URL(fileURLWithPath: "/usr/bin/pkill"),
        arguments: ["-f", "rclone nfsmount \(remoteName):"]
    )
}
```

While `pkill -f` uses regex matching (not shell expansion) and this is passed as a Process argument (not through a shell), a crafted `remoteName` containing regex metacharacters could match unintended processes. For example, `.*` would match all rclone processes.

**Impact**: Unintended process termination via regex injection in remoteName.
**Remediation**: Escape regex metacharacters in `remoteName` before passing to pkill, or use `pgrep` to find exact PIDs first and kill them individually.

---

### FT-04: GitHub API token stored in UserDefaults (HIGH)

**File**: `CrashReporter.swift:47,73`

The crash report key (which appears to be a GitHub personal access token based on its use with `Bearer` auth at line 117) is stored in UserDefaults:

```swift
var token = UserDefaults.standard.string(forKey: "crashReportKey") ?? ""
// ...
UserDefaults.standard.set(entered, forKey: "crashReportKey")
```

UserDefaults is a plaintext plist file readable by any process running as the same user.

**Impact**: GitHub API token exposed in plaintext on disk.
**Remediation**: Store the crash report key in the macOS Keychain instead of UserDefaults.

---

### FT-05: Crash report includes logs and app state (MEDIUM)

**File**: `CrashReporter.swift:168-246`

The `buildIssueBody` method includes in crash reports:
- Last 100 lines of the activity log (may contain mount paths, share names)
- Last 50 lines of rclone logs per share (may contain server names, error details)
- Share count and auto-mount status
- rclone version
- System info (macOS version, Mac model, chip, RAM, disk space)

While crash reports are only sent with user consent, the information disclosure could reveal organizational network infrastructure.

**Impact**: Information disclosure of network infrastructure details in crash reports.
**Remediation**: Document what data is included in crash reports. Consider redacting server hostnames and share names, or at minimum inform users of what will be shared.

---

### FT-06: Activity log file permissions 0644 (MEDIUM)

**File**: `AppLogger.swift:31`

The activity log is created with POSIX permissions `0o644` (owner read/write, group/others read):

```swift
let fd = open(cPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
```

The log contains operational details including mount paths, share names, and process IDs.

**Impact**: Activity log readable by any local user on the machine.
**Remediation**: Use `0o600` permissions (owner read/write only).

---

### FT-07: Share config stored as unencrypted JSON (MEDIUM)

**File**: `ShareStore.swift`

Share configurations including hostnames, usernames, mount points, and share names are stored as unencrypted JSON in Application Support. Passwords are correctly stored in Keychain, but the metadata reveals network infrastructure.

**Impact**: Network infrastructure details accessible to any process running as the same user.
**Remediation**: Accept as low risk since the data does not include credentials. The share configs are operational metadata, not secrets.

---

### FT-08: Redirect follower forwards auth headers to redirected hosts (LOW)

**File**: `CrashReporter.swift:413-433`

The `RedirectFollower` URLSession delegate preserves the Authorization header when following HTTP redirects:

```swift
if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
    redirected.setValue(auth, forHTTPHeaderField: "Authorization")
}
```

If GitHub redirects to a different host, the Bearer token would be sent to that host. GitHub's redirects (307 for repo renames) typically stay within `api.github.com`, but this is a defense-in-depth concern.

**Impact**: Potential credential leakage if redirected to a non-GitHub host.
**Remediation**: Only forward the auth header if the redirect stays on the same host.

---

### FT-09: HelperInstaller uses POSIX-quoted paths (INFO)

**File**: `HelperInstaller.swift:35-43` (Mac Fan Control, not Mirage - noting for reference)

Note: The Mirage app does not have a HelperInstaller. This finding is informational to note that the `createDirectoryPrivileged` method in RcloneProcessManager correctly POSIX-quotes paths, which is the recommended pattern.

---

## Security Posture Assessment

Mirage handles SMB credentials, executes privileged shell commands, and manages external process lifecycle, making it one of the more security-sensitive apps in the portfolio. The critical finding (FT-01) involves command injection with admin privileges through osascript. The password exposure in process arguments (FT-02) and the GitHub token in UserDefaults (FT-04) are significant credential handling issues. On the positive side, the app correctly uses Keychain for password storage, validates rclone version strings with regex, and properly POSIX-quotes paths in the `createDirectoryPrivileged` method.

**Overall Risk**: HIGH - The combination of privilege escalation via osascript and credential exposure requires attention before public distribution.

---

## Remediation Priority

1. **FT-01** (CRITICAL) - POSIX-quote paths in all runPrivileged calls
2. **FT-02** (HIGH) - Pass SMB password via environment variable instead of CLI argument
3. **FT-03** (HIGH) - Escape regex metacharacters in remoteName for pkill
4. **FT-04** (HIGH) - Move crash report key to Keychain
5. **FT-06** (MEDIUM) - Fix log file permissions to 0600
6. **FT-05** (MEDIUM) - Document crash report data contents
7. **FT-07** (MEDIUM) - Accept risk for share config metadata
8. **FT-08** (LOW) - Restrict auth header forwarding to same-host redirects
