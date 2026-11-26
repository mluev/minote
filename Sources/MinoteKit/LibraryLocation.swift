import Foundation

/// Where the library lives.
public enum LibraryStorage: String, Sendable {
    /// On this device only.
    case local
    /// The "Minote" folder in iCloud Drive, shared by all the user's devices.
    case iCloud
}

/// What a move between library folders left behind.
public struct NoteMoveReport: Sendable {
    /// Files that couldn't be moved (or, from iCloud, weren't downloaded in
    /// time). They stay in the old folder, untouched.
    public var leftBehind: [String] = []
    public var firstError: String?
}

/// Where the library folder lives on each platform.
public enum LibraryLocation {
    public static let iCloudContainerIdentifier = "iCloud.com.mlutfullaev.minote"

    /// Copies of emptied notes, on this device only (never synced, always
    /// writable, wherever the library itself lives).
    public static func backupDirectory() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Minote", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    /// macOS: `~/Library/Application Support/Minote/Notes` (inside the app's
    /// sandbox container), like iA Writer's "On My Mac".
    /// iOS: the app's Documents folder, which the Files app shows as
    /// "On My iPhone ▸ Minote", so notes stay ordinary files there too.
    public static func defaultDirectory() -> URL {
        #if os(macOS)
        return URL.applicationSupportDirectory
            .appendingPathComponent("Minote", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
        #else
        return URL.documentsDirectory
        #endif
    }

    /// The "Minote" folder in iCloud Drive, or nil when iCloud Drive is off,
    /// the user is signed out, or the build isn't entitled for iCloud.
    /// Can block for a while the first time: never call it on the main thread.
    public static func iCloudDirectory() -> URL? {
        let manager = FileManager.default
        guard manager.ubiquityIdentityToken != nil,
              let container = manager.url(forUbiquityContainerIdentifier: iCloudContainerIdentifier)
        else { return nil }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? manager.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents
    }

    /// Resolves the iCloud folder off the main thread.
    public static func resolveICloudDirectory() async -> URL? {
        await Task.detached(priority: .userInitiated) { iCloudDirectory() }.value
    }

    /// Moves every note from one library folder to another, into or out of
    /// iCloud, through the system's ubiquity API: each note at the top, and
    /// each folder whole, with everything in it. Never overwrites nor merges:
    /// a name that's taken gets a number. An item that can't be moved stays
    /// where it was and the rest still move. Notes in iCloud that aren't on
    /// this device yet are downloaded first (waiting up to `downloadTimeout`);
    /// a folder holding one that didn't arrive stays behind whole.
    /// Makes blocking file system calls: run it off the main actor.
    public static func moveNotes(from source: URL, to destination: URL, intoICloud: Bool,
                                 downloadTimeout: Duration = .seconds(30)) async throws -> NoteMoveReport {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var report = NoteMoveReport()
        let allFiles = noteFiles(in: source)
        var items = topLevelItems(in: source)

        // Locked notes need their password to come along. A folder already
        // locked with another one would hold notes no single password opens.
        let sourceVault = source.appendingPathComponent(VaultRecord.fileName, isDirectory: false)
        let destinationVault = destination.appendingPathComponent(VaultRecord.fileName, isDirectory: false)
        let movesVault = manager.fileExists(atPath: sourceVault.path)
        if movesVault, manager.fileExists(atPath: destinationVault.path) {
            let ours = try? VaultRecord.decode(Data(contentsOf: sourceVault))
            let theirs = try? VaultRecord.decode(Data(contentsOf: destinationVault))
            if ours?.key.keyID != theirs?.key.keyID, allFiles.contains(where: NoteNaming.isLockedFile) {
                throw LockError.differentPasswords
            }
        }
        let pending = allFiles.filter { !isDownloaded($0) }
        if !pending.isEmpty {
            for file in pending { try? manager.startDownloadingUbiquitousItem(at: file) }
            let deadline = ContinuousClock.now.advanced(by: downloadTimeout)
            while ContinuousClock.now < deadline, !pending.allSatisfy(isDownloaded) {
                try await Task.sleep(for: .milliseconds(250))
            }
            let missing = pending.filter { !isDownloaded($0) }.map(\.standardizedFileURL.path)
            items.removeAll { item in
                let path = item.url.standardizedFileURL.path
                let held = missing.contains { $0 == path || $0.hasPrefix(path + "/") }
                if held { report.leftBehind.append(item.url.lastPathComponent) }
                return held
            }
        }
        for item in items {
            let target: URL
            if item.isFolder {
                let name = NoteNaming.uniqueStem(base: item.url.lastPathComponent) {
                    manager.fileExists(atPath: destination.appendingPathComponent($0).path)
                }
                target = destination.appendingPathComponent(name, isDirectory: true)
            } else {
                let ext = item.url.pathExtension
                let stem = NoteNaming.uniqueStem(base: item.url.deletingPathExtension().lastPathComponent) {
                    manager.fileExists(atPath: destination.appendingPathComponent("\($0).\(ext)").path)
                }
                target = destination.appendingPathComponent("\(stem).\(ext)")
            }
            do {
                if intoICloud {
                    try manager.setUbiquitous(true, itemAt: item.url, destinationURL: target)
                } else if manager.isUbiquitousItem(at: item.url) {
                    try manager.setUbiquitous(false, itemAt: item.url, destinationURL: target)
                } else {
                    try manager.moveItem(at: item.url, to: target)
                }
            } catch {
                report.leftBehind.append(item.url.lastPathComponent)
                report.firstError = report.firstError ?? error.localizedDescription
            }
        }
        // The library folder's own order comes along, unless the destination has one.
        let sourceSettings = source.appendingPathComponent(FolderSettings.fileName, isDirectory: false)
        let destinationSettings = destination.appendingPathComponent(FolderSettings.fileName, isDirectory: false)
        if manager.fileExists(atPath: sourceSettings.path), !manager.fileExists(atPath: destinationSettings.path) {
            if intoICloud {
                try? manager.setUbiquitous(true, itemAt: sourceSettings, destinationURL: destinationSettings)
            } else if manager.isUbiquitousItem(at: sourceSettings) {
                try? manager.setUbiquitous(false, itemAt: sourceSettings, destinationURL: destinationSettings)
            } else {
                try? manager.moveItem(at: sourceSettings, to: destinationSettings)
            }
        }
        if movesVault, !manager.fileExists(atPath: destinationVault.path) {
            do {
                if intoICloud {
                    try manager.setUbiquitous(true, itemAt: sourceVault, destinationURL: destinationVault)
                } else if manager.isUbiquitousItem(at: sourceVault) {
                    try manager.setUbiquitous(false, itemAt: sourceVault, destinationURL: destinationVault)
                } else {
                    try manager.moveItem(at: sourceVault, to: destinationVault)
                }
            } catch {
                // The notes carry their own password records; the vault is rebuilt from them.
                report.firstError = report.firstError ?? error.localizedDescription
            }
        }
        return report
    }

    /// The note files in a folder and every folder below it, including iCloud
    /// notes that are only placeholders (".Name.md.icloud") on this device, by
    /// their real names. Hidden folders, packages and links are skipped.
    static func noteFiles(in directory: URL) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return entries.flatMap { entry -> [URL] in
            let name = entry.lastPathComponent
            if let real = NoteNaming.placeholderTarget(name) {
                return [directory.appendingPathComponent(real, isDirectory: false)]
            }
            guard !name.hasPrefix("."), let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { return [] }
            if values.isDirectory == true {
                return values.isPackage == true ? [] : noteFiles(in: entry)
            }
            return NoteNaming.isNoteFile(entry) && values.isRegularFile == true ? [entry] : []
        }
    }

    /// What a move takes from the top of a library folder: its notes
    /// (placeholders by their real names) and its folders.
    private static func topLevelItems(in directory: URL) -> [(url: URL, isFolder: Bool)] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            if let real = NoteNaming.placeholderTarget(name) {
                return (directory.appendingPathComponent(real, isDirectory: false), false)
            }
            guard !name.hasPrefix("."), let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true else { return nil }
            if values.isDirectory == true { return values.isPackage == true ? nil : (entry, true) }
            return NoteNaming.isNoteFile(entry) && values.isRegularFile == true ? (entry, false) : nil
        }
    }

    /// False only for an iCloud file whose contents aren't on this device.
    private static func isDownloaded(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true else {
            return FileManager.default.fileExists(atPath: url.path)
        }
        return values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded
    }
}

/// Sidebar dates: a time for today, "Yesterday", a weekday within the last
/// week, otherwise a short date (with the year only when it differs).
public enum NoteDateText {
    public static func string(for date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday", locale: locale)
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return date.formatted(style)
    }
}
