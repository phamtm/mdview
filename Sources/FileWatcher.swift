import Foundation

/// Watches a single file and calls back when its contents change.
///
/// Most editors save by writing a temp file and renaming it over the original,
/// which destroys the vnode we were watching. So on any delete/rename we
/// re-open the path and keep watching it.
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "mdview.filewatcher")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var debounce: DispatchWorkItem?
    private var retries = 0

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        queue.async { [weak self] in self?.start() }
    }

    deinit {
        source?.cancel()
    }

    private func start() {
        stop()
        descriptor = Foundation.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Gone for the moment (mid atomic save), or gone for good. Retry for
            // ~10s rather than waking the process every 200ms forever.
            retries += 1
            if retries <= 50 {
                queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() }
            }
            return
        }
        if retries > 0 {
            // The file came back — e.g. after a branch switch. Nothing else will
            // report that, so the reload has to be triggered here.
            retries = 0
            notify()
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.notify()
            if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
                self.queue.asyncAfter(deadline: .now() + 0.1) { self.start() }
            }
        }
        source.setCancelHandler { [descriptor = self.descriptor] in
            if descriptor >= 0 { Foundation.close(descriptor) }
        }
        self.source = source
        source.resume()
    }

    private func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// Coalesce the burst of events a single save produces.
    private func notify() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
