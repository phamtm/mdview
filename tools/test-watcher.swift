// Checks that FileWatcher fires for a plain write and for the temp-file+rename
// dance that most editors do when saving.
import Foundation

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("mdview-watch-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let file = dir.appendingPathComponent("note.md")
try "one\n".write(to: file, atomically: false, encoding: .utf8)

var hits = 0
let lock = NSLock()
let watcher = FileWatcher(url: file) {
    lock.lock(); hits += 1; lock.unlock()
}
_ = watcher

func waitForHit(_ label: String, timeout: TimeInterval = 3.0) -> Bool {
    let before = { lock.lock(); defer { lock.unlock() }; return hits }()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let now = { lock.lock(); defer { lock.unlock() }; return hits }()
        if now > before { print("  ok   \(label)"); return true }
        usleep(50_000)
    }
    print("  FAIL \(label) (no callback in \(timeout)s)")
    return false
}

Thread.sleep(forTimeInterval: 0.4)   // let the watcher arm itself

var passed = true

// 1. plain append
if let handle = try? FileHandle(forWritingTo: file) {
    handle.seekToEndOfFile()
    handle.write("two\n".data(using: .utf8)!)
    try? handle.close()
}
passed = waitForHit("plain write") && passed

// 2. atomic save: write temp, rename over the original
Thread.sleep(forTimeInterval: 0.4)
let temp = dir.appendingPathComponent("note.md.tmp")
try "three\n".write(to: temp, atomically: false, encoding: .utf8)
_ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
passed = waitForHit("atomic save (rename)") && passed

// 3. a write after the rename must still be seen (watcher re-armed)
Thread.sleep(forTimeInterval: 0.6)
if let handle = try? FileHandle(forWritingTo: file) {
    handle.seekToEndOfFile()
    handle.write("four\n".data(using: .utf8)!)
    try? handle.close()
}
passed = waitForHit("write after atomic save") && passed

try? FileManager.default.removeItem(at: dir)
print(passed ? "WATCHER TESTS PASSED" : "WATCHER TESTS FAILED")
exit(passed ? 0 : 1)
