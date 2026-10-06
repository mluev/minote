import Foundation

/// Minimal wrapper over the BSD extended-attribute calls.
/// Attributes travel with the file through moves and renames on APFS.
public enum ExtendedAttributes {
    public static func string(named name: String, at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, name, &buffer, size, 0, XATTR_NOFOLLOW)
            guard read > 0 else { return nil }
            return String(decoding: buffer.prefix(read), as: UTF8.self)
        }
    }

    public static func set(_ value: String, named name: String, at url: URL) throws {
        let data = Array(value.utf8)
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, name, data, data.count, 0, XATTR_NOFOLLOW)
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func remove(named name: String, at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, name, XATTR_NOFOLLOW)
        }
    }

    public static func names(at url: URL) -> [String] {
        url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return [] }
            var buffer = [CChar](repeating: 0, count: size)
            let read = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
            guard read > 0 else { return [] }
            return buffer.prefix(read)
                .split(separator: 0)
                .map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
    }
}
