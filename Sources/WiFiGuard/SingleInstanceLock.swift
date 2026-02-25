import Foundation
import Darwin

final class SingleInstanceLock {
    static let shared = SingleInstanceLock()
    
    private var fd: Int32 = -1
    
    /// Attempts to acquire a process-wide exclusive lock.
    /// Returns `true` if this instance should continue running, `false` if another instance is already running.
    func acquire() -> Bool {
        if fd != -1 { return true }
        
        let bundleID = Bundle.main.bundleIdentifier ?? "APSwitcher"
        let lockFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(bundleID).lock", isDirectory: false)
        
        let newFD = open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        if newFD == -1 {
            // If we can't create the lock file, allow running rather than bricking the app.
            return true
        }
        
        if flock(newFD, LOCK_EX | LOCK_NB) != 0 {
            close(newFD)
            return false
        }
        
        // Best-effort: record pid in lock file for debugging.
        _ = ftruncate(newFD, 0)
        let pidString = "\(ProcessInfo.processInfo.processIdentifier)\n"
        pidString.withCString { ptr in
            _ = write(newFD, ptr, strlen(ptr))
        }
        
        fd = newFD
        return true
    }
}
