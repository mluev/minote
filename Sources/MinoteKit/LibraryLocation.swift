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
    public var moved = 0
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
    /// iCloud, through the system's ubiquity API. Never overwrites: a name
    /// that's taken gets a number. A file that can't be moved stays where it
    /// was and the rest still move. Notes in iCloud that aren't on this device
    /// yet are downloaded first (waiting up to `downloadTimeout`).
    /// Makes blocking file system calls: run it off the main actor.
    public static func moveNotes(from source: URL, to destination: URL, intoICloud: Bool,
                                 downloadTimeout: Duration = .seconds(30)) async throws -> NoteMoveReport {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var report = NoteMoveReport()
        var files = noteFiles(in: source)
        let pending = files.filter { !isDownloaded($0) }
        if !pending.isEmpty {
            for file in pending { try? manager.startDownloadingUbiquitousItem(at: file) }
            let deadline = ContinuousClock.now.advanced(by: downloadTimeout)
            while ContinuousClock.now < deadline, !pending.allSatisfy(isDownloaded) {
                try await Task.sleep(for: .milliseconds(250))
            }
            for file in pending where !isDownloaded(file) {
                report.leftBehind.append(file.lastPathComponent)
                files.removeAll { $0 == file }
            }
        }
        for file in files {
            let ext = file.pathExtension
            let stem = NoteNaming.uniqueStem(base: file.deletingPathExtension().lastPathComponent) {
                manager.fileExists(atPath: destination.appendingPathComponent("\($0).\(ext)").path)
            }
            let target = destination.appendingPathComponent("\(stem).\(ext)")
            do {
                if intoICloud {
                    try manager.setUbiquitous(true, itemAt: file, destinationURL: target)
                } else if manager.isUbiquitousItem(at: file) {
                    try manager.setUbiquitous(false, itemAt: file, destinationURL: target)
                } else {
                    try manager.moveItem(at: file, to: target)
                }
                report.moved += 1
            } catch {
                report.leftBehind.append(file.lastPathComponent)
                report.firstError = report.firstError ?? error.localizedDescription
            }
        }
        return report
    }

    /// The note files in a folder, including iCloud notes that are only
    /// placeholders (".Name.md.icloud") on this device, by their real names.
    static func noteFiles(in directory: URL) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [URL] = []
        for entry in entries {
            var name = entry.lastPathComponent
            if name.hasPrefix(".") {
                guard name.hasSuffix(".icloud") else { continue }
                name = String(name.dropFirst().dropLast(".icloud".count))
                let file = directory.appendingPathComponent(name, isDirectory: false)
                if NoteNaming.isNoteFile(file) { files.append(file) }
                continue
            }
            guard NoteNaming.isNoteFile(entry),
                  (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            files.append(entry)
        }
        return files
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
