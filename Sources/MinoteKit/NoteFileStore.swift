import Foundation
import os

/// What the library remembers about a file on disk to detect outside changes cheaply.
public struct FileStamp: Sendable, Equatable {
    public let modified: Date
    public let size: Int

    public init(modified: Date, size: Int) {
        self.modified = modified
        self.size = size
    }
}

/// One note file found by a scan.
public struct ScannedFile: Sendable {
    public let url: URL
    public let stamp: FileStamp
    /// The file name Minote gave the file, if it created it.
    public let autoNameTag: String?
    /// Contents, or nil when the stamp matched what the caller already knew.
    public let text: String?
}

/// A file Minote has just written.
public struct SavedFile: Sendable {
    public let url: URL
    public let stamp: FileStamp
}

/// Moves a file to the Trash and returns where it went (needed for undo).
public typealias TrashHandler = @Sendable (URL) throws -> URL?

/// All disk access for one library folder. Every method is synchronous inside
/// the actor, so operations never interleave with each other.
public actor NoteFileStore {
    /// Extended attribute holding the stem Minote chose for a file it created.
    /// While it matches the file's current name, the file follows its first line.
    public static let autoNameAttribute = "com.mlutfullaev.minote.autoname"

    public nonisolated let directory: URL
    /// iCloud folders need file coordination, placeholder downloads and
    /// conflict handling; local folders don't.
    public nonisolated let isUbiquitous: Bool

    private let trashHandler: TrashHandler
    private var lastWrittenRevision: [UUID: Int] = [:]
    private let logger = Logger(subsystem: "com.mlutfullaev.minote", category: "FileStore")

    private var fileManager: FileManager { .default }

    public init(directory: URL, isUbiquitous: Bool = false, trash: @escaping TrashHandler = NoteFileStore.moveToSystemTrash) {
        // Create first so symlinks such as /var → /private/var resolve and every URL
        // we build matches what directory listings return.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.isUbiquitous = isUbiquitous
        self.trashHandler = trash
    }

    public static let moveToSystemTrash: TrashHandler = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: Folder

    /// Makes sure the library folder exists.
    public func prepare() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Lists every note file. Contents are read only for files whose stamp
    /// differs from `known`, so periodic rescans stay cheap.
    public func scan(known: [URL: FileStamp]) throws -> [ScannedFile] {
        try prepare()
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let listing = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsSubdirectoryDescendants]
        )

        var files: [ScannedFile] = []
        for entry in listing {
            let name = entry.lastPathComponent
            if name.hasPrefix(".") {
                // iCloud keeps notes that aren't on this device yet as hidden
                // ".Name.md.icloud" placeholders: ask for the real file.
                if isUbiquitous, name.hasSuffix(".icloud") {
                    let real = String(name.dropFirst().dropLast(".icloud".count))
                    if NoteNaming.isNoteFile(URL(fileURLWithPath: real)) {
                        try? fileManager.startDownloadingUbiquitousItem(at: fileURL(named: real))
                    }
                }
                continue
            }
            guard NoteNaming.isNoteFile(entry) else { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let url = fileURL(named: entry.lastPathComponent)
            let stamp = FileStamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
            let tag = ExtendedAttributes.string(named: Self.autoNameAttribute, at: url)

            if known[url] == stamp {
                files.append(ScannedFile(url: url, stamp: stamp, autoNameTag: tag, text: nil))
                continue
            }
            do {
                let text = try readText(at: url)
                if isUbiquitous { preserveConflicts(of: url) }
                files.append(ScannedFile(url: url, stamp: stamp, autoNameTag: tag, text: text))
            } catch {
                logger.error("Skipping unreadable file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return files
    }

    // MARK: Reading and writing

    public func readText(at url: URL) throws -> String {
        var data = Data()
        try coordinate(reading: url) { data = try Data(contentsOf: $0) }
        if var text = String(data: data, encoding: .utf8) {
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return text
        }
        // Not UTF-8: let Foundation recognize UTF-16/32 (by their byte order
        // marks) and legacy encodings, falling back to Windows Latin 1, which
        // decodes any bytes. Saving writes UTF-8 from then on.
        var converted: NSString?
        let options: [StringEncodingDetectionOptionsKey: Any] = [
            .suggestedEncodingsKey: [String.Encoding.utf16.rawValue, String.Encoding.windowsCP1252.rawValue],
            .allowLossyKey: false,
        ]
        _ = NSString.stringEncoding(for: data, encodingOptions: options, convertedString: &converted, usedLossyConversion: nil)
        if let converted { return converted as String }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
    }

    /// Creates a new auto-named file for `text`, named after `base` (or "base 2", …).
    public func create(text: String, base: String) throws -> SavedFile {
        try prepare()
        let data = Data(text.utf8)
        while true {
            let stem = NoteNaming.uniqueStem(base: base) { fileExists(stem: $0, ext: NoteNaming.fileExtension) }
            let url = fileURL(stem: stem, ext: NoteNaming.fileExtension)
            do {
                try coordinate(writing: url, options: .forReplacing) { try data.write(to: $0, options: .withoutOverwriting) }
            } catch where fileManager.fileExists(atPath: url.path) {
                continue // Another process took the name between our check and the write.
            }
            tag(url, with: stem)
            return SavedFile(url: url, stamp: try stamp(of: url))
        }
    }

    /// Replaces the file's contents safely. Returns nil when a newer revision of the
    /// same note was already written (an out-of-order save is dropped, never applied).
    public func write(_ text: String, to url: URL, autoNameTag: String?, noteID: UUID, revision: Int) throws -> FileStamp? {
        if let last = lastWrittenRevision[noteID], revision <= last { return nil }
        if text.isBlank { backUpBeforeEmptying(url) }
        let data = Data(text.utf8)
        try coordinate(writing: url, options: .forReplacing) { try safeWrite(data, to: $0) }
        if let autoNameTag { tag(url, with: autoNameTag) }
        lastWrittenRevision[noteID] = revision
        return try stamp(of: url)
    }

    /// Atomic replace that keeps the original's creation date, Finder labels and
    /// extended attributes (Finder tags live in an xattr).
    private func safeWrite(_ data: Data, to url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary)
        try copyExtendedAttributes(from: url, to: temporary)
        _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
    }

    private func copyExtendedAttributes(from source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_XATTR))
            }
        }
        if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Where the previous contents of emptied notes are kept, just in case.
    public nonisolated var backupDirectory: URL {
        directory.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    /// A note is about to be emptied: keep what it had. Emptying a note is
    /// usually deliberate, but a writing app must never be the reason text is gone.
    private func backUpBeforeEmptying(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return }
        do {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = backupDirectory.appendingPathComponent("\(stamp) \(url.lastPathComponent)")
            try fileManager.copyItem(at: url, to: backup)
            pruneBackups()
        } catch {
            logger.error("Couldn't back up \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keeps the newest 50 backups.
    private func pruneBackups() {
        guard let items = try? fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil) else { return }
        for old in items.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(50) {
            try? fileManager.removeItem(at: old)
        }
    }

    // MARK: Renaming

    /// Renames the file to follow `base`, keeping its extension. Returns the
    /// (possibly unchanged) URL. Never overwrites another file.
    public func rename(_ url: URL, toBase base: String) throws -> URL {
        let ext = url.pathExtension
        let current = url.deletingPathExtension().lastPathComponent
        let stem = NoteNaming.uniqueStem(base: base) { candidate in
            let candidateURL = fileURL(stem: candidate, ext: ext)
            return fileManager.fileExists(atPath: candidateURL.path) && !isSameFile(candidateURL, url)
        }
        guard stem != current else { return url }

        let destination = fileURL(stem: stem, ext: ext)
        try move(url, to: destination, caseOnly: NoteNaming.stemsMatch(stem, current))
        tag(destination, with: stem)
        return destination
    }

    /// Renames without ever replacing another file, coordinated for iCloud.
    private func move(_ source: URL, to destination: URL, caseOnly: Bool) throws {
        try coordinate(moving: source, to: destination) { from, to in
            let status = from.withUnsafeFileSystemRepresentation { src in
                to.withUnsafeFileSystemRepresentation { dst -> Int32 in
                    guard let src, let dst else { return -1 }
                    // On a case-insensitive volume the destination of a case-only rename
                    // "exists" (it's the same file), so exclusive rename would refuse it.
                    return caseOnly ? Foundation.rename(src, dst) : renamex_np(src, dst, UInt32(RENAME_EXCL))
                }
            }
            if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// A name the user chose: the file stops following its first line.
    /// Refuses to replace another file.
    public func renameManually(_ url: URL, to stem: String) throws -> URL {
        let ext = url.pathExtension
        let destination = fileURL(stem: stem, ext: ext)
        let current = url.deletingPathExtension().lastPathComponent
        if stem != current {
            if fileManager.fileExists(atPath: destination.path), !isSameFile(destination, url) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
            }
            try move(url, to: destination, caseOnly: NoteNaming.stemsMatch(stem, current))
        }
        ExtendedAttributes.remove(named: Self.autoNameAttribute, at: destination)
        return destination
    }

    /// Copies a note to "Name copy.md" (or "Name copy 2.md"), named by hand.
    public func duplicate(_ url: URL) throws -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent + " copy"
        let stem = NoteNaming.uniqueStem(base: base) { fileExists(stem: $0, ext: ext) }
        let destination = fileURL(stem: stem, ext: ext)
        try fileManager.copyItem(at: url, to: destination)
        ExtendedAttributes.remove(named: Self.autoNameAttribute, at: destination)
        return destination
    }

    // MARK: Trash

    /// Moves the file to the Trash. Returns the trashed location for undo.
    public func trash(_ url: URL) throws -> URL? {
        var trashed: URL?
        try coordinate(writing: url, options: .forDeleting) { trashed = try trashHandler($0) }
        return trashed
    }

    /// Puts a trashed file back into the library, under a free name.
    public func restore(_ trashedURL: URL, preferredName: String) throws -> URL {
        try prepare()
        let ext = (preferredName as NSString).pathExtension
        let base = (preferredName as NSString).deletingPathExtension
        let stem = NoteNaming.uniqueStem(base: base) { fileExists(stem: $0, ext: ext) }
        let destination = fileURL(stem: stem, ext: ext)
        try fileManager.moveItem(at: trashedURL, to: destination)
        // An auto-named file that had to take a new name stays auto-named.
        if stem != base,
           let tag = ExtendedAttributes.string(named: Self.autoNameAttribute, at: destination),
           NoteNaming.stemsMatch(tag, base) {
            self.tag(destination, with: stem)
        }
        return destination
    }

    // MARK: iCloud

    private func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        guard isUbiquitous else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        guard isUbiquitous else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private func coordinate(moving source: URL, to destination: URL, _ body: (URL, URL) throws -> Void) throws {
        guard isUbiquitous else { return try body(source, destination) }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var bodyError: Error?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &coordinationError) { from, to in
            do {
                try body(from, to)
                coordinator.item(at: from, didMoveTo: to)
            } catch {
                bodyError = error
            }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    /// When two devices edited the same note, iCloud keeps one version and
    /// flags the others as conflicts. Nothing is thrown away: every other
    /// version becomes its own note, "Name (conflict 2).md".
    private func preserveConflicts(of url: URL) {
        guard let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty else { return }
        let ext = url.pathExtension
        var keptAll = true
        for version in conflicts {
            let base = url.deletingPathExtension().lastPathComponent + " (conflict)"
            let stem = NoteNaming.uniqueStem(base: base) { fileExists(stem: $0, ext: ext) }
            do {
                try fileManager.copyItem(at: version.url, to: fileURL(stem: stem, ext: ext))
                ExtendedAttributes.remove(named: Self.autoNameAttribute, at: fileURL(stem: stem, ext: ext))
                version.isResolved = true
            } catch {
                keptAll = false
                logger.error("Couldn't keep a conflicting version of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Old versions go only once every one of them is safely a note.
        if keptAll { try? NSFileVersion.removeOtherVersionsOfItem(at: url) }
    }

    // MARK: Helpers

    public nonisolated func fileURL(named name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    nonisolated func fileURL(stem: String, ext: String) -> URL {
        fileURL(named: ext.isEmpty ? stem : "\(stem).\(ext)")
    }

    private func fileExists(stem: String, ext: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(stem: stem, ext: ext).path)
    }

    private func tag(_ url: URL, with stem: String) {
        do {
            try ExtendedAttributes.set(stem, named: Self.autoNameAttribute, at: url)
        } catch {
            logger.error("Could not tag \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads the stamp through a fresh URL so no cached resource values are used.
    private func stamp(of url: URL) throws -> FileStamp {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileStamp(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
    }

    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? URL(fileURLWithPath: a.path).resourceValues(forKeys: key).fileResourceIdentifier,
              let idB = try? URL(fileURLWithPath: b.path).resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }
}
