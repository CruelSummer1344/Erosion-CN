import Foundation
import Darwin
import CryptoKit

let fm = FileManager.default
func L(_ value: String) -> String { value }

@main
struct Regressions {
    static var failures = 0
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { print("FAIL: \(message)"); failures += 1 }
    }
    static func version(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        for v in [version(26, 0), version(26, 7, 2), version(27, 0), version(27, 2, 1)] {
            check(SystemCompatibility.supportsApp(v), "documented supported version \(v)")
        }
        for v in [version(25, 9), version(26, 7, 3), version(26, 8), version(27, 2, 2), version(27, 3), version(28, 0)] {
            check(!SystemCompatibility.supportsApp(v), "reject unverified version \(v)")
        }
        check(!SystemCompatibility.supportsMobileGestalt(version(26, 7, 2)), "iOS 26 must not write MobileGestalt")
        check(SystemCompatibility.supportsMobileGestalt(version(27, 2, 1)), "verified iOS 27 can write MobileGestalt")

        let target = root.appendingPathComponent("target")
        let original = Data("original content".utf8)
        let replacement = Data("new".utf8)
        try original.write(to: target)
        let inode = try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber
        check(writeFileAtomically(replacement, to: target).0, "normal in-place write succeeds")
        check(tryData(target) == replacement, "shorter writes truncate the old tail")
        let writtenInode = try fm.attributesOfItem(atPath: target.path)[.systemFileNumber] as! NSNumber
        check(writtenInode == inode, "in-place write preserves inode")
        check(!writeFileAtomically(Data(), to: target).0, "empty writes rejected by default")
        check(tryData(target) == replacement, "rejected empty write leaves file intact")
        check(writeFileAtomically(Data(), to: target, allowEmpty: true).0, "intentional empty text files supported")
        check(tryData(target) == Data(), "intentional empty write truncates file")
        let link = root.appendingPathComponent("symlink")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        check(!writeFileAtomically(original, to: link).0, "symlink target is rejected")
        check(!writeFileAtomically(original, to: root.appendingPathComponent("missing")).0, "missing originals rejected")

        // Inject a real partial pwrite, followed by each supported rollback failure.
        for failure in ["none", "write", "truncate", "sync", "readback"] {
            try original.write(to: target)
            var operations = InPlaceWriteOperations.live
            let live = InPlaceWriteOperations.live
            var writes = 0
            operations.write = { fd, data in
                writes += 1
                if writes == 1 {
                    try live.write(fd, Data(data.prefix(1)))
                    throw CocoaError(.fileWriteUnknown)
                }
                if failure == "write" { throw CocoaError(.fileWriteUnknown) }
                try live.write(fd, data)
            }
            if failure == "truncate" { operations.truncate = { _, _ in throw CocoaError(.fileWriteUnknown) } }
            if failure == "sync" { operations.sync = { _ in throw CocoaError(.fileWriteUnknown) } }
            if failure == "readback" {
                var reads = 0
                operations.read = { fd in
                    reads += 1
                    return reads == 1 ? try live.read(fd) : Data("mismatch".utf8)
                }
            }
            let result = writeFileAtomically(replacement, to: target, operations: operations)
            check(!result.0, "partial write reports failure: \(failure)")
            if failure == "none" {
                check(tryData(target) == original, "partial write is restored byte for byte")
                check(result.1.contains("已读回确认"), "rollback success requires readback")
            } else {
                check(result.1.contains("无法确认回滚成功"), "rollback \(failure) must not claim recovery")
            }
        }
        // A readback failure after an otherwise complete write also restores the original.
        try original.write(to: target)
        var corruptReadback = InPlaceWriteOperations.live
        let live = InPlaceWriteOperations.live
        var readCount = 0
        corruptReadback.read = { fd in
            readCount += 1
            return readCount == 2 ? Data("bad readback".utf8) : try live.read(fd)
        }
        check(!writeFileAtomically(replacement, to: target, operations: corruptReadback).0, "write readback mismatch reports failure")
        check(tryData(target) == original, "readback mismatch restores original")

        let backup = root.appendingPathComponent("backup.plist")
        let digest = root.appendingPathComponent("backup.sha256")
        try VerifiedBackup.write(original, to: backup, digestURL: digest)
        check(tryData(backup) == original, "backup bytes verified")
        let expectedDigest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        check(tryData(digest) == Data(expectedDigest.utf8), "backup digest matches data")
        do {
            try VerifiedBackup.write(original, to: backup, digestURL: root)
            check(false, "digest write failure must be propagated")
        } catch { check(true, "digest write failure propagated") }
        do {
            try VerifiedBackup.write(original, to: root, digestURL: digest)
            check(false, "backup write failure must be propagated")
        } catch { check(true, "backup write failure propagated") }
        print("\(checks) checks, \(failures) failures")
        if failures > 0 { exit(1) }
    }
    static func tryData(_ url: URL) -> Data? { try? Data(contentsOf: url) }
}
