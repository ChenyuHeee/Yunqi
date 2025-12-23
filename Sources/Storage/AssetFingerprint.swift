import Foundation

/// Best-effort, stable-ish fingerprint for cache invalidation.
///
/// Goals:
/// - Changes when the underlying file content likely changed.
/// - Cheap to compute.
/// - Safe to use in cache keys.
///
/// Note: This is not cryptographic and may miss some edge cases (e.g. content changes without mtime/size change).
public enum AssetFingerprint {
    public static func compute(url: URL) -> String? {
        // Only support file URLs for now.
        guard url.isFileURL else { return nil }

        // Prefer FileManager attributes for inode/system file number access.
        // Keep URLResourceValues fallback so the fingerprint works for basic metadata even
        // if some attributes aren't available.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let values = (try? url.resourceValues(forKeys: keys))

        var parts: [String] = []

        if let inode = attrs[.systemFileNumber] as? NSNumber {
            parts.append("i\(inode.int64Value)")
        }

        if let size = (attrs[.size] as? NSNumber)?.int64Value {
            parts.append("s\(size)")
        } else if let size = values?.fileSize {
            parts.append("s\(size)")
        }

        let mtime = (attrs[.modificationDate] as? Date) ?? values?.contentModificationDate
        if let mtime {
            // Quantize to milliseconds for stability.
            let ms = Int64((mtime.timeIntervalSince1970 * 1000.0).rounded(.toNearestOrAwayFromZero))
            parts.append("m\(ms)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    public static func fnv1a64Hex(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 0x00000100000001B3
        }
        return String(format: "%016llx", h)
    }
}
