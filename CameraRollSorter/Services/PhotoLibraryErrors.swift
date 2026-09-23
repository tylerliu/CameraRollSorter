import Photos

/// Helpers for interpreting PhotoKit errors from delete/convert flows.
enum PhotoLibraryErrors {
    /// True when the error is the user tapping **Cancel** on the system
    /// "Delete Photos?" / change confirmation prompt, rather than a real
    /// failure. PhotoKit reports this as `PHPhotosError.userCancelled`
    /// (`PHPhotosErrorDomain` code 3072). We treat it as a no-op and show no
    /// error alert.
    static func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.userCancelled.rawValue {
            return true
        }
        // Belt-and-suspenders: also treat a Foundation cancellation as cancel.
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return true
        }
        return false
    }
}
