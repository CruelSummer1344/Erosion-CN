//
//  WriteHelpers.swift
//  Erosion
//
//  Verified in-place writes with best-effort rollback. Not crash-atomic.
//

import Foundation
import Darwin

private func fullFsyncSafe(_ fd: Int32) -> Bool {
    if fcntl(fd, F_FULLFSYNC) == 0 {
        return true
    }
    return fsync(fd) == 0
}

func writeFileTemp(_ data: Data, to url: URL) -> (Bool, String) {
    guard !data.isEmpty else {
        return (false, L("拒绝写入 0 字节空数据！"))
    }
    do {
        var statBuf = stat()
        let hasOriginal = (stat(url.path, &statBuf) == 0)

        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: [.withoutOverwriting])
        defer { try? fm.removeItem(at: tempURL) }

        if hasOriginal {
            _ = chmod(tempURL.path, statBuf.st_mode & 0o7777)
            _ = chown(tempURL.path, statBuf.st_uid, statBuf.st_gid)
            let _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            _ = chmod(url.path, statBuf.st_mode & 0o7777)
            _ = chown(url.path, statBuf.st_uid, statBuf.st_gid)
        } else {
            try fm.moveItem(at: tempURL, to: url)
        }

        return (true, "succeeded")
    } catch {
        print("(fm) failed to write file: \(error.localizedDescription)")
        return (false, error.localizedDescription)
    }
}

/// The operations seam permits deterministic partial-write and rollback failure tests.
struct InPlaceWriteOperations {
    var write: (Int32, Data) throws -> Void
    var truncate: (Int32, off_t) throws -> Void
    var sync: (Int32) throws -> Void
    var read: (Int32) throws -> Data

    static var live: Self {
        Self(
            write: { try pwriteAll($0, $1, startOffset: 0) },
            truncate: { fd, length in
                guard ftruncate(fd, length) == 0 else { throw fileWriteErr.truncate(errno: errno) }
            },
            sync: { fd in
                guard fullFsyncSafe(fd) else { throw fileWriteErr.sync(errno: errno) }
            },
            read: { fd in
                guard lseek(fd, 0, SEEK_SET) == 0 else { throw fileWriteErr.verificationFailed }
                return try readAll(fd)
            }
        )
    }
}

/// Preserves the existing inode. Never pre-truncates nonempty writes, and verifies both
/// writes and rollback. A process exit or power loss during pwrite can still leave partial data.
func writeFileAtomically(_ data: Data, to url: URL, allowEmpty: Bool = false,
                         operations: InPlaceWriteOperations = .live) -> (Bool, String) {
    if !allowEmpty && data.isEmpty {
        return (false, L("安全拦截：禁止向目标文件原位写入 0 字节空数据！"))
    }

    let fd = url.path.withCString { open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW) }
    guard fd >= 0 else { return (false, fileWriteErr.open(errno: errno).localizedDescription) }
    defer { close(fd) }

    // Read the original through the same descriptor we will modify.
    let original: Data
    do {
        original = try operations.read(fd)
    } catch {
        return (false, L("无法读取原文件备份数据，已中止原位写入！"))
    }

    do {
        try operations.write(fd, data)
        if data.count < original.count { try operations.truncate(fd, off_t(data.count)) }
        try operations.sync(fd)
        guard try operations.read(fd) == data else { throw fileWriteErr.verificationFailed }
        return (true, "succeeded")
    } catch {
        let writeError = error
        do {
            try operations.write(fd, original)
            try operations.truncate(fd, off_t(original.count))
            try operations.sync(fd)
            guard try operations.read(fd) == original else { throw fileWriteErr.verificationFailed }
            return (false, L("写入失败，已读回确认原文件恢复：\(writeError.localizedDescription)"))
        } catch {
            return (false, L("写入失败且无法确认回滚成功；请勿重启设备，请使用备份恢复。写入错误：\(writeError.localizedDescription)；回滚错误：\(error.localizedDescription)"))
        }
    }
}

private enum fileWriteErr: LocalizedError {
    case open(errno: Int32)
    case truncate(errno: Int32)
    case write(errno: Int32)
    case sync(errno: Int32)
    case rollback(errno: Int32)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .open(let e): return L("打开文件描述符失败 (errno=\(e))")
        case .truncate(let e): return L("裁剪文件尾部失败 (errno=\(e))")
        case .write(let e): return L("写入文件块失败 (errno=\(e))")
        case .sync(let e): return L("物理闪存同步 F_FULLFSYNC 失败 (errno=\(e))")
        case .rollback(let e): return L("回滚文件失败 (errno=\(e))")
        case .verificationFailed: return L("写后描述符字节比对不一致")
        }
    }
}

private func readAll(_ fd: Int32) throws -> Data {
    var res = Data()
    var buf = [UInt8](repeating: 0, count: 64 * 1024)

    while true {
        let count = buf.withUnsafeMutableBytes { rawBuffer in
            read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if count > 0 {
            res.append(buf, count: count)
            continue
        }
        if count == 0 {
            return res
        }
        if errno == EINTR {
            continue
        }
        throw fileWriteErr.verificationFailed
    }
}

private func pwriteAll(_ fd: Int32, _ data: Data, startOffset: off_t) throws {
    guard !data.isEmpty else { return }

    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else {
            throw fileWriteErr.write(errno: EFAULT)
        }

        var written = 0
        while written < data.count {
            let res = pwrite(
                fd,
                base.advanced(by: written),
                data.count - written,
                startOffset + off_t(written)
            )
            if res > 0 {
                written += res
                continue
            }
            if res < 0 && errno == EINTR {
                continue
            }
            throw fileWriteErr.write(errno: errno)
        }
    }
}
