import DiskArbitration
import Foundation

/// Notices drives arriving and leaving, as it happens.
///
/// Polling would eventually notice too, but the delay is the whole problem: a
/// drive pulled out while the list is on screen leaves a row offering to open
/// something that is no longer there. DiskArbitration reports both events
/// immediately and needs no privileges.
public final class DiskWatcher {
    private var session: DASession?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session

        // Unretained: the watcher owns the session, so it cannot outlive one.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let notify: DADiskAppearedCallback = { _, context in
            guard let context else { return }
            Unmanaged<DiskWatcher>.fromOpaque(context).takeUnretainedValue().schedule()
        }
        DARegisterDiskAppearedCallback(session, nil, notify, context)
        DARegisterDiskDisappearedCallback(session, nil, notify, context)
        DASessionScheduleWithRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func stop() {
        guard let session else { return }
        DASessionUnscheduleFromRunLoop(
            session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.session = nil
        pending?.cancel()
        pending = nil
    }

    /// One drive produces a callback per partition, and unplugging a drive with
    /// three volumes on it produces a burst. Rescanning on each would run the
    /// scan several times over for a single event, so let the burst finish.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    deinit { stop() }
}
