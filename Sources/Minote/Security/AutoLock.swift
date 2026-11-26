import AppKit
import MinoteKit

/// Locks the notes when the Mac goes to sleep, its screen sleeps or locks,
/// the screen saver starts, or the user switches to another account; calls
/// `onReturn` when the user is back (screen unlocked), for Touch ID to ask.
/// Idle time is `LockController`'s; quitting needs nothing (the key lives in memory).
final class AutoLock {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(lock: LockController, onReturn: @escaping @MainActor () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observe(name, in: workspace, lock: lock)
        }
        // Not documented, but posted by the system and delivered in the sandbox.
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observe(Notification.Name(name), in: distributed, lock: lock)
        }
        let token = distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { onReturn() }
        }
        observers.append((distributed, token))
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, lock: LockController) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak lock] _ in
            MainActor.assumeIsolated { lock?.lockNow() }
        }
        observers.append((center, token))
    }
}
