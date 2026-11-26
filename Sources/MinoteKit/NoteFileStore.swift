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

    init(_ values: URLResourceValues) {
        self.init(modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
    }
}

/// What a scan read from a note file.
public enum ScannedContent: Sendable {
    case plain(String)
    /// A locked note. `text` is there when the sealer given to the scan opened it.
    case locked(KeyRecord, text: String?)
}

/// One note file found by a scan.
public struct ScannedFile: Sendable {
    public let url: URL
    /// The library folder it's in.
    public var folder: FolderPath = .root
    public let stamp: FileStamp
    /// When the file was made (its modification date where that's unknown).
    public var created: Date
    /// The file name Minote gave the file, if it created it.
    public let autoNameTag: String?
    /// Contents, or nil when the stamp matched what the caller already knew.
    public let content: ScannedContent?

    /// The readable text: a plain note's, or a locked note's the scan could open.
    public var text: String? {
        switch content {
        case .plain(let text): text
        case .locked(_, let text): text
        case nil: nil
        }
    }

    init(url: URL, folder: FolderPath = .root, stamp: FileStamp, created: Date? = nil, autoNameTag: String?, content: ScannedContent?) {
        self.url = url
        self.folder = folder
        self.stamp = stamp
        self.created = created ?? stamp.modified
        self.autoNameTag = autoNameTag
        self.content = content
    }
}

/// One folder found by a scan, below the library folder.
public struct ScannedFolder: Sendable, Equatable {
    public let path: FolderPath
}

/// Everything a scan found: the notes, every folder (empty ones too), and
/// the settings of the folders that have them (the library folder's too).
public struct ScanResult: Sendable {
    public var files: [ScannedFile] = []
    public var folders: [ScannedFolder] = []
    public var settings: [FolderPath: FolderSettings.Read] = [:]
}

/// Why a folder command was refused.
public enum FolderError: LocalizedError, Equatable {
    case nameTaken(String)
    case intoItself
    case missing

    public var errorDescription: String? {
        switch self {
        case .nameTaken(let name): "There's already an item named “\(name)” there."
        case .intoItself: "A folder can't go inside itself."
        case .missing: "The folder isn't there any more."
        }
    }
}

/// What to write into a note file. A locked note's file only ever receives
/// sealed bytes, and a plain note's file never does.
public enum NotePayload: Sendable {
    case plain(String)
    /// A locked note's text, already sealed. `isBlank` tells whether that text is empty.
    case sealed(Data, isBlank: Bool)

    var isSealed: Bool {
        if case .sealed = self { true } else { false }
    }

    var isBlank: Bool {
        switch self {
        case .plain(let text): text.isBlank
        case .sealed(_, let isBlank): isBlank
        }
    }

    var data: Data {
        switch self {
        case .plain(let text): Data(text.utf8)
        case .sealed(let data, _): data
        }
    }

    var fileExtension: String {
        isSealed ? NoteNaming.lockedExtension : NoteNaming.fileExtension
    }
}

/// A file Minote has just written.
public struct SavedFile: Sendable {
    public let url: URL
    public let stamp: FileStamp
}

/// Moves a file to the Trash and returns where it went (needed for undo).
public typealias TrashHandler = @Sendable (URL) throws -> URL?

/// All disk access for one library folder, or for one file opened from
/// elsewhere (`init(file:backupDirectory:)`). Every method is synchronous
/// inside the actor, so operations never interleave with each other.
public actor NoteFileStore {
    /// Extended attribute holding the stem Minote chose for a file it created.
    /// While it matches the file's current name, the file follows its first line.
    public static let autoNameAttribute = "com.mlutfullaev.minote.autoname"
    /// Ties a note file to its backups across renames, so locking it can
    /// delete every plain copy (see `removeBackups(of:)`).
    static let backupIDAttribute = "com.mlutfullaev.minote.backup-id"

    public nonisolated let directory: URL
    /// The one file this store manages when it was opened from outside the
    /// library (File ▸ Open…, Finder), or nil for a library folder. Such a store
    /// reads and writes that file in place and never lists, creates, renames or
    /// trashes anything: the sandbox grants access to the file, not its folder.
    public nonisolated let singleFile: URL?
    /// iCloud folders need file coordination, placeholder downloads and
    /// conflict handling; local folders don't.
    public nonisolated let isUbiquitous: Bool
    /// Where the previous contents of emptied notes are kept, just in case.
    public nonisolated let backupDirectory: URL

    private let trashHandler: TrashHandler
    private var lastWrittenRevision: [UUID: Int] = [:]
    /// The backup IDs of the plain notes the last scan saw, by stem, and the
    /// stems of its locked notes: a note that turns up locked (by another
    /// device too) takes its plain backups on this one with it.
    private var plainBackupIDs: [String: String] = [:]
    /// How many locked notes the last scan saw under each file name: a name
    /// counted more often than before has a note newly locked. By name, not
    /// path, so a folder renamed or moved doesn't look like new locks.
    private var lockedNameCounts: [String: Int] = [:]
    private let logger = Logger(subsystem: "com.mlutfullaev.minote", category: "FileStore")

    private var fileManager: FileManager { .default }

    /// `backupDirectory` defaults to a "Backups" folder next to the library folder.
    public init(directory: URL, isUbiquitous: Bool = false, backupDirectory: URL? = nil,
                trash: @escaping TrashHandler = NoteFileStore.moveToSystemTrash) {
        // Create first so symlinks such as /var → /private/var resolve and every URL
        // we build matches what directory listings return.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.singleFile = nil
        self.isUbiquitous = isUbiquitous
        self.backupDirectory = backupDirectory
            ?? self.directory.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        self.trashHandler = trash
    }

    /// A store for one file opened from elsewhere. Its folder is neither created
    /// nor listed, and the file is never renamed, trashed or auto-named.
    public init(file: URL, backupDirectory: URL) {
        let file = file.standardizedFileURL.resolvingSymlinksInPath()
        self.singleFile = file
        self.directory = file.deletingLastPathComponent()
        self.isUbiquitous = false
        self.backupDirectory = backupDirectory
        self.trashHandler = { _ in throw CocoaError(.featureUnsupported) }
    }

    public static let moveToSystemTrash: TrashHandler = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    // MARK: Folder

    /// Makes sure the library folder exists.
    public func prepare() throws {
        guard singleFile == nil else { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let scanKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey,
        .contentModificationDateKey, .creationDateKey, .fileSizeKey,
    ]

    /// Lists every note file, in the library folder and every folder below it.
    public func scan(known: [URL: FileStamp], sealer: NoteSealer? = nil) throws -> [ScannedFile] {
        try scanTree(known: known, sealer: sealer).files
    }

    /// Lists every note file and every folder under the library folder.
    /// Contents are read only for files whose stamp differs from `known`, so
    /// periodic rescans stay cheap. Locked notes are opened with `sealer` when
    /// it holds their key, and stay sealed otherwise. Hidden items, packages
    /// and symbolic links are skipped, with everything inside them.
    public func scanTree(known: [URL: FileStamp], sealer: NoteSealer? = nil) throws -> ScanResult {
        if let singleFile {
            // The opened file alone, or nothing while it's missing. Minote's naming
            // tag is ignored: a file opened from elsewhere never follows its first
            // line, even a copy of a note Minote created.
            guard let values = try? URL(fileURLWithPath: singleFile.path).resourceValues(forKeys: Self.scanKeys),
                  values.isRegularFile == true else { return ScanResult() }
            let stamp = FileStamp(values)
            let text = known[singleFile] == stamp ? nil : try readText(at: singleFile)
            return ScanResult(files: [ScannedFile(url: singleFile, stamp: stamp, created: values.creationDate,
                                                  autoNameTag: nil, content: text.map(ScannedContent.plain))])
        }
        try prepare()

        var result = ScanResult()
        var locked: [String: URL] = [:]
        var backupIDs: [String: String] = [:]
        var pending: [FolderPath] = [.root]
        while let folder = pending.popLast() {
            let folderURL = folderURL(folder)
            let listing: [URL]
            do {
                listing = try fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: Array(Self.scanKeys))
            } catch where !folder.isRoot {
                // A folder that went away mid-scan, or can't be read: the rest still counts.
                logger.error("Skipping unreadable folder: \(error.localizedDescription, privacy: .public)")
                continue
            }
            for entry in listing {
                let name = entry.lastPathComponent
                if name == FolderSettings.fileName {
                    result.settings[folder] = readFolderSettings(at: entry)
                    continue
                }
                if name.hasPrefix(".") {
                    // A note, or a folder's settings, that isn't on this device yet: ask iCloud for it.
                    if isUbiquitous, name == ".\(FolderSettings.fileName).icloud" {
                        try? fileManager.startDownloadingUbiquitousItem(at: fileURL(named: FolderSettings.fileName, in: folderURL))
                    } else if isUbiquitous, let real = NoteNaming.placeholderTarget(name) {
                        try? fileManager.startDownloadingUbiquitousItem(at: fileURL(named: real, in: folderURL))
                    }
                    continue
                }
                guard let values = try? entry.resourceValues(forKeys: Self.scanKeys), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    guard values.isPackage != true else { continue }
                    let path = folder.appending(name)
                    result.folders.append(ScannedFolder(path: path))
                    pending.append(path)
                    continue
                }
                guard NoteNaming.isNoteFile(entry), values.isRegularFile == true else { continue }
                let url = fileURL(named: name, in: folderURL)
                let stamp = FileStamp(values)
                let tag = ExtendedAttributes.string(named: Self.autoNameAttribute, at: url)
                let key = Self.stemKey(folder.relativePath(ofFile: url.deletingPathExtension().lastPathComponent))
                if NoteNaming.isLockedFile(url) {
                    locked[key] = url
                } else if let id = ExtendedAttributes.string(named: Self.backupIDAttribute, at: url) {
                    backupIDs[key] = id
                }

                if known[url] == stamp {
                    result.files.append(ScannedFile(url: url, folder: folder, stamp: stamp, created: values.creationDate,
                                                    autoNameTag: tag, content: nil))
                    continue
                }
                do {
                    let content = try readContent(at: url, sealer: sealer)
                    if isUbiquitous { preserveConflicts(of: url) }
                    result.files.append(ScannedFile(url: url, folder: folder, stamp: stamp, created: values.creationDate,
                                                    autoNameTag: tag, content: content))
                } catch {
                    logger.error("Skipping unreadable file \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        var counts: [String: Int] = [:]
        for url in locked.values { counts[Self.stemKey(url.deletingPathExtension().lastPathComponent), default: 0] += 1 }
        let grown = Set(counts.filter { $0.value > (lockedNameCounts[$0.key] ?? 0) }.keys)
        let newlyLocked = locked.filter { grown.contains(Self.stemKey($0.value.deletingPathExtension().lastPathComponent)) }
        if !newlyLocked.isEmpty { removePlainBackups(ofLocked: newlyLocked) }
        lockedNameCounts = counts
        plainBackupIDs = backupIDs
        return result
    }

    /// Notes that turned up locked: at launch, or locked on another device,
    /// whose own `convert` deleted only its own backups. Their plain backups
    /// here go: by name, and by the backup ID the note had while it was plain
    /// (seen by an earlier scan, or carried over in the locked file's
    /// attributes). Backups of the locked note itself are sealed, and stay.
    private func removePlainBackups(ofLocked locked: [String: URL]) {
        guard let items = try? fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil) else { return }
        var ids = Set<String>()
        // Backups are named by file name alone: a same-named plain note in
        // another folder loses its backups too, which errs on the lock's side.
        var names = Set<String>()
        for (key, url) in locked {
            if let id = plainBackupIDs[key] { ids.insert(id) }
            if let id = ExtendedAttributes.string(named: Self.backupIDAttribute, at: url) { ids.insert(id) }
            names.insert(Self.stemKey(url.deletingPathExtension().lastPathComponent))
        }
        for item in items {
            // "<date> <file name>"
            guard let name = item.lastPathComponent.split(separator: " ", maxSplits: 1).last.map(String.init) else { continue }
            let original = URL(fileURLWithPath: name)
            guard NoteNaming.isPlainNoteFile(original) else { continue }
            let sameName = names.contains(Self.stemKey(original.deletingPathExtension().lastPathComponent))
            let sameID = ExtendedAttributes.string(named: Self.backupIDAttribute, at: item).map(ids.contains) ?? false
            guard sameName || sameID else { continue }
            do {
                try fileManager.removeItem(at: item)
                logger.notice("Removed a plain backup of a note that's now locked")
            } catch {
                logger.error("Couldn't remove a plain backup: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Names that `NoteNaming.stemsMatch` takes for the same.
    private static func stemKey(_ stem: String) -> String {
        stem.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func readContent(at url: URL, sealer: NoteSealer?) throws -> ScannedContent {
        guard NoteNaming.isLockedFile(url) else { return .plain(try readText(at: url)) }
        let data = try readData(at: url)
        let record = try LockedNoteFile.record(of: data)
        guard let sealer, sealer.canOpen(record.keyID) else { return .locked(record, text: nil) }
        do {
            return .locked(record, text: try sealer.open(data).text)
        } catch {
            logger.error("Couldn't open locked note \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .locked(record, text: nil)
        }
    }

    // MARK: Reading and writing

    private func readData(at url: URL) throws -> Data {
        var data = Data()
        try coordinate(reading: url) { data = try Data(contentsOf: $0) }
        return data
    }

    /// A locked note's text and the key ID it was sealed with.
    public func openLocked(at url: URL, with sealer: NoteSealer) throws -> (text: String, keyID: UUID) {
        try sealer.open(readData(at: url))
    }

    /// The password record a locked note was sealed with.
    public func lockedRecord(at url: URL) throws -> KeyRecord {
        try LockedNoteFile.record(of: readData(at: url))
    }

    /// A plain note's text. Refuses a locked note, whatever its name: decoded
    /// as text it would be shown, and saved, as garbage.
    public func readText(at url: URL) throws -> String {
        let data = try readData(at: url)
        if LockedNoteFile.isLocked(data) { throw LockError.lockedNote }
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
    public func create(text: String, base: String, in folder: FolderPath = .root) throws -> SavedFile {
        try create(.plain(text), base: base, in: folder)
    }

    /// Creates a new auto-named note file in `folder`, named after `base` (or
    /// "base 2", …): a locked note when the payload is sealed, so its text is
    /// never on disk in the clear, not even for a moment. A folder that went
    /// away is made again: the note's text matters more than its absence.
    public func create(_ payload: NotePayload, base: String, in folder: FolderPath = .root) throws -> SavedFile {
        try requireFolder()
        try prepare()
        let folderURL = folderURL(folder)
        if !folder.isRoot { try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true) }
        let data = payload.data
        while true {
            let stem = NoteNaming.uniqueStem(base: base) { stemTaken($0, in: folderURL) }
            let url = fileURL(stem: stem, ext: payload.fileExtension, in: folderURL)
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
        try write(.plain(text), to: url, autoNameTag: autoNameTag, noteID: noteID, revision: revision)
    }

    /// Replaces the file's contents safely. Returns nil when a newer revision of the
    /// same note was already written (an out-of-order save is dropped, never applied).
    /// Plain text never goes into a locked note's file, nor sealed bytes into a plain one.
    public func write(_ payload: NotePayload, to url: URL, autoNameTag: String?, noteID: UUID, revision: Int) throws -> FileStamp? {
        let lockedFile = singleFile == nil && NoteNaming.isLockedFile(url)
        if lockedFile && !payload.isSealed { throw LockError.notUnlocked }
        if !lockedFile && payload.isSealed { throw LockError.lockedNote }
        if let last = lastWrittenRevision[noteID], revision <= last { return nil }
        if payload.isBlank { backUpBeforeEmptying(url) }
        let data = payload.data
        try coordinate(writing: url, options: .forReplacing) { try safeWrite(data, to: $0) }
        if let autoNameTag { tag(url, with: autoNameTag) }
        lastWrittenRevision[noteID] = revision
        return try stamp(of: url)
    }

    /// Locks a plain note or unlocks a locked one for good: writes the new file
    /// under the same name (or a free one), then deletes the old file. Deletes,
    /// never trashes: a plain copy in the Trash would defeat the lock. Locking
    /// also deletes the backups that hold the note's plain text.
    public func convert(_ url: URL, to payload: NotePayload) throws -> SavedFile {
        try requireFolder()
        let currentStem = url.deletingPathExtension().lastPathComponent
        let folderURL = url.deletingLastPathComponent()
        let autoNameTag = ExtendedAttributes.string(named: Self.autoNameAttribute, at: url)
        let created = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.creationDateKey]).creationDate
        let data = payload.data
        while true {
            let stem = NoteNaming.uniqueStem(base: currentStem) { stemTaken($0, except: url, in: folderURL) }
            let destination = fileURL(stem: stem, ext: payload.fileExtension, in: folderURL)
            do {
                try coordinate(writing: destination, options: .forReplacing) { try data.write(to: $0, options: .withoutOverwriting) }
            } catch where fileManager.fileExists(atPath: destination.path) {
                continue
            }
            // Finder tags, labels and the naming tag come along, and the
            // creation date: locking mustn't reorder a list sorted by it.
            try? copyExtendedAttributes(from: url, to: destination)
            if let created { try? fileManager.setAttributes([.creationDate: created], ofItemAtPath: destination.path) }
            if stem != currentStem, let autoNameTag, NoteNaming.stemsMatch(autoNameTag, currentStem) {
                tag(destination, with: stem)
            }
            do {
                try coordinate(writing: url, options: .forDeleting) { try fileManager.removeItem(at: $0) }
            } catch {
                // Leave things as they were rather than with two copies of the note.
                try? coordinate(writing: destination, options: .forDeleting) { try fileManager.removeItem(at: $0) }
                throw error
            }
            if payload.isSealed {
                removeBackups(of: url.lastPathComponent, id: ExtendedAttributes.string(named: Self.backupIDAttribute, at: destination))
            }
            return SavedFile(url: destination, stamp: try stamp(of: destination))
        }
    }

    /// Atomic replace that keeps the original's creation date, Finder labels and
    /// extended attributes (Finder tags live in an xattr). An opened file's
    /// sandbox grant doesn't cover its folder, where an atomic write stages its
    /// temporary file: a missing one is written in place, and if the system
    /// refuses the replacement, the file is overwritten in place rather than
    /// left unsaved.
    private func safeWrite(_ data: Data, to url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            try data.write(to: url, options: singleFile == nil ? .atomic : [])
            return
        }
        do {
            let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fileManager.removeItem(at: scratch) }
            let temporary = scratch.appendingPathComponent(url.lastPathComponent)
            try data.write(to: temporary)
            try copyExtendedAttributes(from: url, to: temporary)
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary, backupItemName: nil, options: [])
        } catch where singleFile != nil {
            logger.notice("Replacing \(url.lastPathComponent, privacy: .public) failed, writing in place: \(error.localizedDescription, privacy: .public)")
            try data.write(to: url)
        }
    }

    private func copyExtendedAttributes(from source: URL, to destination: URL) throws {
        let status = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_XATTR))
            }
        }
        if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// A note is about to be emptied: keep what it had. Emptying a note is
    /// usually deliberate, but a writing app must never be the reason text is gone.
    private func backUpBeforeEmptying(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { return }
        do {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = backupDirectory.appendingPathComponent("\(stamp) \(url.lastPathComponent)")
            // Saving keeps extended attributes, so the ID follows the note.
            let id = ExtendedAttributes.string(named: Self.backupIDAttribute, at: url) ?? UUID().uuidString
            try? ExtendedAttributes.set(id, named: Self.backupIDAttribute, at: url)
            try fileManager.copyItem(at: url, to: backup)
            try? ExtendedAttributes.set(id, named: Self.backupIDAttribute, at: backup)
            pruneBackups()
        } catch {
            logger.error("Couldn't back up \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes the backups of a file, by its backup ID (made under any of its
    /// names) or by name ("<date> <file name>", for backups older than IDs):
    /// a locked note's earlier plain text must not outlive the lock.
    private func removeBackups(of name: String, id: String?) {
        guard let items = try? fileManager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            let sameName = item.lastPathComponent.split(separator: " ", maxSplits: 1).last.map(String.init) == name
            let sameID = id != nil && ExtendedAttributes.string(named: Self.backupIDAttribute, at: item) == id
            if sameName || sameID { try? fileManager.removeItem(at: item) }
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
        try requireFolder()
        let stem = NoteNaming.uniqueStem(base: base) { stemTaken($0, except: url, in: url.deletingLastPathComponent()) }
        guard stem != url.deletingPathExtension().lastPathComponent else { return url }
        let destination = try move(url, toStem: stem)
        tag(destination, with: stem)
        return destination
    }

    /// A name the user chose: the file stops following its first line.
    /// Refuses to replace another file.
    public func renameManually(_ url: URL, to stem: String) throws -> URL {
        try requireFolder()
        let destination = fileURL(stem: stem, ext: url.pathExtension, in: url.deletingLastPathComponent())
        if stemTaken(stem, except: url, in: url.deletingLastPathComponent()) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination.path])
        }
        _ = try move(url, toStem: stem)
        ExtendedAttributes.remove(named: Self.autoNameAttribute, at: destination)
        return destination
    }

    /// Renames the file to `stem`, keeping its extension, without ever
    /// replacing another file; coordinated for iCloud.
    private func move(_ url: URL, toStem stem: String) throws -> URL {
        let current = url.deletingPathExtension().lastPathComponent
        let destination = fileURL(stem: stem, ext: url.pathExtension, in: url.deletingLastPathComponent())
        guard stem != current else { return destination }
        // On a case-insensitive volume the destination of a case-only rename
        // "exists" (it's the same file), so an exclusive rename would refuse it.
        try exclusiveMove(url, to: destination, caseOnly: NoteNaming.stemsMatch(stem, current))
        return destination
    }

    /// Copies a note to "Name copy.md" (or "Name copy 2.md"), named by hand.
    public func duplicate(_ url: URL) throws -> URL {
        try requireFolder()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent + " copy"
        let folderURL = url.deletingLastPathComponent()
        let stem = NoteNaming.uniqueStem(base: base) { stemTaken($0, in: folderURL) }
        let destination = fileURL(stem: stem, ext: ext, in: folderURL)
        try coordinate(writing: destination, options: .forReplacing) { try fileManager.copyItem(at: url, to: $0) }
        ExtendedAttributes.remove(named: Self.autoNameAttribute, at: destination)
        ExtendedAttributes.remove(named: Self.backupIDAttribute, at: destination)
        return destination
    }

    // MARK: Trash

    /// Moves the file to the Trash. Returns the trashed location for undo.
    public func trash(_ url: URL) throws -> URL? {
        var trashed: URL?
        try coordinate(writing: url, options: .forDeleting) { trashed = try trashHandler($0) }
        return trashed
    }

    /// Puts a trashed file back into the library folder it came from (made
    /// again if it's gone), under a free name.
    public func restore(_ trashedURL: URL, preferredName: String, in folder: FolderPath = .root) throws -> URL {
        try requireFolder()
        try prepare()
        let folderURL = folderURL(folder)
        if !folder.isRoot { try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true) }
        let ext = (preferredName as NSString).pathExtension
        let base = (preferredName as NSString).deletingPathExtension
        let stem = NoteNaming.uniqueStem(base: base) { stemTaken($0, in: folderURL) }
        let destination = fileURL(stem: stem, ext: ext, in: folderURL)
        if isUbiquitous, !fileManager.isUbiquitousItem(at: trashedURL) {
            // A file enters iCloud Drive through the ubiquity API, not a plain move.
            try fileManager.setUbiquitous(true, itemAt: trashedURL, destinationURL: destination)
        } else {
            try coordinate(moving: trashedURL, to: destination) { try fileManager.moveItem(at: $0, to: $1) }
        }
        // An auto-named file that had to take a new name stays auto-named.
        if stem != base,
           let tag = ExtendedAttributes.string(named: Self.autoNameAttribute, at: destination),
           NoteNaming.stemsMatch(tag, base) {
            self.tag(destination, with: stem)
        }
        return destination
    }

    // MARK: iCloud

    /// iCloud needs coordinated access. So does a file opened from elsewhere: it
    /// may sit in iCloud Drive or a synced folder, and other editors may have it open.
    private nonisolated var coordinates: Bool { isUbiquitous || singleFile != nil }

    private func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        guard coordinates else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions, _ body: (URL) throws -> Void) throws {
        guard coordinates else { return try body(url) }
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private func coordinate(moving source: URL, to destination: URL, _ body: (URL, URL) throws -> Void) throws {
        guard coordinates else { return try body(source, destination) }
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
        let folderURL = url.deletingLastPathComponent()
        for version in conflicts {
            let base = url.deletingPathExtension().lastPathComponent + " (conflict)"
            let stem = NoteNaming.uniqueStem(base: base) { stemTaken($0, in: folderURL) }
            let destination = fileURL(stem: stem, ext: ext, in: folderURL)
            let source = version.url
            do {
                try coordinate(writing: destination, options: .forReplacing) { try fileManager.copyItem(at: source, to: $0) }
                ExtendedAttributes.remove(named: Self.autoNameAttribute, at: destination)
                ExtendedAttributes.remove(named: Self.backupIDAttribute, at: destination)
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

    /// Naming, copying and restoring place files in the library folder, which an
    /// opened file's store doesn't have.
    private func requireFolder() throws {
        if singleFile != nil { throw CocoaError(.featureUnsupported) }
    }

    /// A file in the library folder itself.
    public nonisolated func fileURL(named name: String) -> URL {
        fileURL(named: name, in: directory)
    }

    /// A library folder's URL. Every URL the store hands out is built from
    /// these, so the same file always gets an equal URL.
    public nonisolated func folderURL(_ folder: FolderPath) -> URL {
        folder.url(in: directory)
    }

    /// The library folder a file of the library is in.
    public nonisolated func folder(of url: URL) -> FolderPath {
        FolderPath(folderOf: url, root: directory) ?? .root
    }

    nonisolated func fileURL(named name: String, in folderURL: URL) -> URL {
        folderURL.appendingPathComponent(name, isDirectory: false)
    }

    nonisolated func fileURL(stem: String, ext: String, in folderURL: URL) -> URL {
        fileURL(named: ext.isEmpty ? stem : "\(stem).\(ext)", in: folderURL)
    }

    /// Whether some note in `folderURL` already has this name, with any
    /// extension the library lists: "Ideas.md" and "Ideas.mdlock" side by
    /// side would be two notes with one name, and locking one would collide
    /// with the other. Other folders may have a note of that name.
    private func stemTaken(_ stem: String, except url: URL? = nil, in folderURL: URL) -> Bool {
        for ext in NoteNaming.supportedExtensions.union([NoteNaming.lockedExtension]) {
            let candidate = fileURL(stem: stem, ext: ext, in: folderURL)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if let url, isSameFile(candidate, url) { continue }
            return true
        }
        return false
    }

    // MARK: Folders

    /// A folder's settings file: what it says, or nil when it can't be read
    /// yet. In iCloud, the current version wins over conflicting ones.
    private func readFolderSettings(at url: URL) -> FolderSettings.Read? {
        if isUbiquitous, let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !conflicts.isEmpty {
            for version in conflicts { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        guard let data = try? readData(at: url) else { return nil }
        return FolderSettings.decode(data)
    }

    /// Writes a folder's settings, or removes the file when there's nothing to keep.
    public func writeFolderSettings(_ settings: FolderSettings?, for folder: FolderPath) throws {
        try requireFolder()
        let folderURL = folderURL(folder)
        let url = fileURL(named: FolderSettings.fileName, in: folderURL)
        if let settings, !settings.isEmpty {
            guard fileManager.fileExists(atPath: folderURL.path) else { throw FolderError.missing }
            let data = try settings.encoded()
            try coordinate(writing: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
        } else if fileManager.fileExists(atPath: url.path) {
            try coordinate(writing: url, options: .forDeleting) { try fileManager.removeItem(at: $0) }
        }
    }

    /// Makes a new folder in `parent`, named `base` or "base 2", … Returns it.
    public func createFolder(named base: String, in parent: FolderPath) throws -> FolderPath {
        try requireFolder()
        try prepare()
        let parentURL = folderURL(parent)
        guard fileManager.fileExists(atPath: parentURL.path) else { throw FolderError.missing }
        let base = NoteNaming.folderName(for: base)
        while true {
            let name = NoteNaming.uniqueStem(base: base) { fileManager.fileExists(atPath: parentURL.appendingPathComponent($0).path) }
            let url = parentURL.appendingPathComponent(name, isDirectory: true)
            do {
                try coordinate(writing: url, options: []) { try fileManager.createDirectory(at: $0, withIntermediateDirectories: false) }
                return parent.appending(name)
            } catch where fileManager.fileExists(atPath: url.path) {
                continue // Taken between our check and the write.
            }
        }
    }

    /// Renames a folder; refuses a name another item beside it has.
    public func renameFolder(_ folder: FolderPath, to newName: String) throws -> FolderPath {
        try requireFolder()
        guard let parent = folder.parent, let current = folder.name else { throw FolderError.missing }
        let name = NoteNaming.folderName(for: newName)
        guard name != current else { return folder }
        let source = folderURL(folder)
        let destination = folderURL(parent).appendingPathComponent(name, isDirectory: true)
        let caseOnly = NoteNaming.stemsMatch(name, current)
        if !caseOnly && fileManager.fileExists(atPath: destination.path) { throw FolderError.nameTaken(name) }
        try exclusiveMove(source, to: destination, caseOnly: caseOnly)
        return parent.appending(name)
    }

    /// Moves a folder, with everything in it, into `parent`. Refuses to move
    /// it into itself or below, and onto an item of the same name: folders
    /// are never merged.
    public func moveFolder(_ folder: FolderPath, into parent: FolderPath) throws -> FolderPath {
        try requireFolder()
        guard let name = folder.name else { throw FolderError.missing }
        if folder.contains(parent) { throw FolderError.intoItself }
        if folder.parent == parent { return folder }
        let destination = folderURL(parent).appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) { throw FolderError.nameTaken(name) }
        try exclusiveMove(folderURL(folder), to: destination, caseOnly: false)
        return parent.appending(name)
    }

    /// Moves a note into another folder, under a free name there (a number
    /// added); an auto-named note that had to take a new name stays auto-named.
    public func moveNote(_ url: URL, to folder: FolderPath) throws -> URL {
        try requireFolder()
        let folderURL = folderURL(folder)
        guard fileManager.fileExists(atPath: folderURL.path) else { throw FolderError.missing }
        let base = url.deletingPathExtension().lastPathComponent
        while true {
            let stem = NoteNaming.uniqueStem(base: base) { stemTaken($0, in: folderURL) }
            let destination = fileURL(stem: stem, ext: url.pathExtension, in: folderURL)
            do {
                try exclusiveMove(url, to: destination, caseOnly: false)
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
            if stem != base,
               let tag = ExtendedAttributes.string(named: Self.autoNameAttribute, at: destination),
               NoteNaming.stemsMatch(tag, base) {
                self.tag(destination, with: stem)
            }
            return destination
        }
    }

    /// Moves a folder, with everything in it, to the Trash as one item.
    public func trashFolder(_ folder: FolderPath) throws -> URL? {
        try requireFolder()
        guard !folder.isRoot else { throw FolderError.missing }
        var trashed: URL?
        try coordinate(writing: folderURL(folder), options: .forDeleting) { trashed = try trashHandler($0) }
        return trashed
    }

    /// Puts a trashed folder back into `parent` (made again if it's gone),
    /// under a free name.
    public func restoreFolder(_ trashedURL: URL, named name: String, in parent: FolderPath) throws -> FolderPath {
        try requireFolder()
        try prepare()
        let parentURL = folderURL(parent)
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let free = NoteNaming.uniqueStem(base: name) { fileManager.fileExists(atPath: parentURL.appendingPathComponent($0).path) }
        let destination = parentURL.appendingPathComponent(free, isDirectory: true)
        if isUbiquitous, !fileManager.isUbiquitousItem(at: trashedURL) {
            try fileManager.setUbiquitous(true, itemAt: trashedURL, destinationURL: destination)
        } else {
            try coordinate(moving: trashedURL, to: destination) { try fileManager.moveItem(at: $0, to: $1) }
        }
        return parent.appending(free)
    }

    /// Notes and other files in a folder and below: what trashing it takes.
    /// iCloud notes not on this device yet count as notes.
    public func contentsCount(of folder: FolderPath) -> (notes: Int, others: Int) {
        guard let walker = fileManager.enumerator(at: folderURL(folder), includingPropertiesForKeys: [.isRegularFileKey]) else { return (0, 0) }
        var notes = 0, others = 0
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if NoteNaming.placeholderTarget(name) != nil { notes += 1 }
                walker.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if NoteNaming.isNoteFile(url) { notes += 1 } else { others += 1 }
        }
        return (notes, others)
    }

    /// Renames or moves an item without ever replacing another; coordinated for iCloud.
    private func exclusiveMove(_ source: URL, to destination: URL, caseOnly: Bool) throws {
        try coordinate(moving: source, to: destination) { from, to in
            let status = from.withUnsafeFileSystemRepresentation { src in
                to.withUnsafeFileSystemRepresentation { dst -> Int32 in
                    guard let src, let dst else { return -1 }
                    return caseOnly ? Foundation.rename(src, dst) : renamex_np(src, dst, UInt32(RENAME_EXCL))
                }
            }
            if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    // MARK: Vault

    /// The library's password record and lock mode (see `VaultRecord`).
    public func readVault() -> VaultRead {
        guard singleFile == nil else { return .missing }
        let url = fileURL(named: VaultRecord.fileName)
        guard fileManager.fileExists(atPath: url.path) else {
            if isUbiquitous, fileManager.fileExists(atPath: fileURL(named: ".\(VaultRecord.fileName).icloud").path) {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
                return .pending
            }
            return .missing
        }
        do {
            return .found(try VaultRecord.decode(readData(at: url)))
        } catch {
            logger.error("Couldn't read the vault: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
    }

    /// Writes the vault, or removes it for nil.
    public func writeVault(_ vault: VaultRecord?) throws {
        try requireFolder()
        try prepare()
        let url = fileURL(named: VaultRecord.fileName)
        if let vault {
            let data = try vault.encoded()
            try coordinate(writing: url, options: .forReplacing) { try data.write(to: $0, options: .atomic) }
        } else if fileManager.fileExists(atPath: url.path) {
            try coordinate(writing: url, options: .forDeleting) { try fileManager.removeItem(at: $0) }
        }
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
        try FileStamp(URL(fileURLWithPath: url.path).resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
    }

    private func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? URL(fileURLWithPath: a.path).resourceValues(forKeys: key).fileResourceIdentifier,
              let idB = try? URL(fileURLWithPath: b.path).resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }
}
