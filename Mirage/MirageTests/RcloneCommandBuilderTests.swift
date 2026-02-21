import XCTest
@testable import Mirage

final class RcloneCommandBuilderTests: XCTestCase {
    func testCreateRemoteArguments() {
        let builder = RcloneCommandBuilder(
            rclonePath: "/usr/local/bin/rclone",
            cacheBaseDir: "/tmp/cache",
            logBaseDir: "/tmp/logs"
        )

        let args = builder.createRemoteArguments(
            name: "test-remote",
            host: "192.168.1.100",
            username: "admin",
            password: "secret"
        )

        XCTAssertEqual(args[0], "config")
        XCTAssertEqual(args[1], "create")
        XCTAssertEqual(args[2], "test-remote")
        XCTAssertEqual(args[3], "smb")
        XCTAssertTrue(args.contains("host=192.168.1.100"))
        XCTAssertTrue(args.contains("user=admin"))
        XCTAssertTrue(args.contains("pass=secret"))
    }

    func testMountArguments() {
        let builder = RcloneCommandBuilder(
            rclonePath: "/usr/local/bin/rclone",
            cacheBaseDir: "/tmp/cache",
            logBaseDir: "/tmp/logs"
        )

        let share = SMBShareConfig(
            displayName: "Test",
            host: "192.168.1.100",
            shareName: "Documents",
            subfolder: "Projects",
            username: "admin",
            cacheMode: .full,
            autoMount: true
        )

        let args = builder.mountArguments(share: share)

        XCTAssertEqual(args[0], "nfsmount")
        XCTAssertTrue(args.contains("--vfs-cache-mode"))
        XCTAssertTrue(args.contains("full"))
        XCTAssertTrue(args.contains("--cache-dir"))
        XCTAssertTrue(args.contains("--volname"))
    }

    func testCacheDirPaths() {
        let builder = RcloneCommandBuilder(
            rclonePath: "/usr/local/bin/rclone",
            cacheBaseDir: "/tmp/cache",
            logBaseDir: "/tmp/logs"
        )

        let id = UUID()
        let cacheDir = builder.cacheDirPath(for: id)
        let nfsDir = builder.nfsCacheDirPath(for: id)

        XCTAssertTrue(cacheDir.contains(id.uuidString))
        XCTAssertTrue(nfsDir.contains(id.uuidString))
        XCTAssertNotEqual(cacheDir, nfsDir)
    }

    func testDurationFormatting() {
        let builder = RcloneCommandBuilder(
            rclonePath: "/usr/local/bin/rclone",
            cacheBaseDir: "/tmp/cache",
            logBaseDir: "/tmp/logs"
        )

        // Test via mount arguments with specific durations
        let share = SMBShareConfig(
            displayName: "Test",
            host: "192.168.1.100",
            shareName: "Docs",
            username: "admin",
            cacheMode: .full,
            cacheMaxAge: 3600,  // 1 hour
            writeBack: 5,       // 5 seconds
            cachePollInterval: 60, // 1 minute
            autoMount: true
        )

        let args = builder.mountArguments(share: share)

        // Verify durations are properly formatted
        if let ageIdx = args.firstIndex(of: "--vfs-cache-max-age") {
            XCTAssertEqual(args[ageIdx + 1], "1h")
        }
        if let wbIdx = args.firstIndex(of: "--vfs-write-back") {
            XCTAssertEqual(args[wbIdx + 1], "5s")
        }
        if let pollIdx = args.firstIndex(of: "--vfs-cache-poll-interval") {
            XCTAssertEqual(args[pollIdx + 1], "1m")
        }
    }

    func testRemotePathWithSubfolder() {
        let share = SMBShareConfig(
            displayName: "Test",
            host: "192.168.1.100",
            shareName: "Documents",
            subfolder: "Projects/2024",
            username: "admin"
        )

        XCTAssertTrue(share.remotePath.contains("Documents/Projects/2024"))
    }

    func testRemotePathWithoutSubfolder() {
        let share = SMBShareConfig(
            displayName: "Test",
            host: "192.168.1.100",
            shareName: "Documents",
            subfolder: "",
            username: "admin"
        )

        XCTAssertTrue(share.remotePath.hasSuffix(":Documents"))
    }
}
