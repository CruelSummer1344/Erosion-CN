import Foundation
import CryptoKit

/// Only reports success after both files have been read back and compared.
enum VerifiedBackup {
    static func write(_ data: Data, to plistURL: URL, digestURL: URL) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let digestData = Data(digest.utf8)
        try data.write(to: plistURL, options: .atomic)
        try digestData.write(to: digestURL, options: .atomic)
        guard try Data(contentsOf: plistURL) == data,
              try Data(contentsOf: digestURL) == digestData else {
            throw NSError(domain: "Erosion.Backup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L("备份写后读回校验失败")])
        }
    }
}
