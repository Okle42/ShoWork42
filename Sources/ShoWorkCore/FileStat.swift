import Foundation

/// 便宜的 lstat（10-21 CPU 突波）：`FileManager.attributesOfItem` 每次都會順便讀延伸屬性（getxattr／listxattr）、
/// 檔案保護等級（getattrlist），看板每輪對上百個檔做這件事，取樣裡 getxattr 是讀檔路徑上最大宗。
/// 這裡只要 mtime／大小／種類，直接 lstat（跟 attributesOfItem 一樣不跟隨符號連結）。
public enum FileStat {
    public struct Info: Sendable, Equatable {
        public var mtime: Double        // 秒（含奈秒）
        public var size: Int
        public var mode: mode_t
        public var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
        public var isRegular: Bool { mode & S_IFMT == S_IFREG }
        public var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
        public var date: Date { Date(timeIntervalSince1970: mtime) }
        /// 「內容可能變了」的戳記（mtime＋大小）
        public var stamp: String { "\(mtime)|\(size)" }
    }
    public static func lstat(_ path: String) -> Info? {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return nil }
        return Info(mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9, size: Int(st.st_size), mode: st.st_mode)
    }
}
