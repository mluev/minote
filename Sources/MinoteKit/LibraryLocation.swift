import Foundation

/// Where the library folder lives. The single place to change when the
/// library moves (e.g. into the iCloud container).
/// Where the library lives.
public enum LibraryStorage: String, Sendable {
    /// On this device only.
    case local
    /// The "Minote" folder in iCloud Drive, shared by all the user's devices.
    case iCloud
}

public enum LibraryLocation {
    public static let iCloudContainerIdentifier = "iCloud.com.mlutfullaev.minote"

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
    /// that's taken gets a number. Blocking: run off the main thread.
    public static func moveNotes(from source: URL, to destination: URL, intoICloud: Bool) throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let files = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { NoteNaming.isNoteFile($0) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        var moved = 0
        for file in files {
            let ext = file.pathExtension
            let stem = NoteNaming.uniqueStem(base: file.deletingPathExtension().lastPathComponent) {
                manager.fileExists(atPath: destination.appendingPathComponent("\($0).\(ext)").path)
            }
            let target = destination.appendingPathComponent("\(stem).\(ext)")
            if intoICloud {
                try manager.setUbiquitous(true, itemAt: file, destinationURL: target)
            } else if manager.isUbiquitousItem(at: file) {
                try manager.setUbiquitous(false, itemAt: file, destinationURL: target)
            } else {
                try manager.moveItem(at: file, to: target)
            }
            moved += 1
        }
        return moved
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
