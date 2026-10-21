import Cocoa
import SQLite3

/// Mirrors every macOS notification (any app) into the bar's notification area, with the app's icon.
/// Source: Notification Center's own database, read-only, polled once a second. Verified 2026-10-06 on macOS 14.7.6:
/// readable without Full Disk Access; Teams, Outlook and kitty all deliver there. Records disappear when dismissed,
/// so polling picks each one up on delivery. rec_id is reused after deletes (no AUTOINCREMENT), so new records are
/// found by delivery time and de-duplicated by uuid.
final class NotificationMirror {
    static let shared = NotificationMirror()

    private let queue = DispatchQueue(label: "MTMRNotificationMirror")
    private var options: NotificationMirrorOptions?
    private var timer: Timer?
    private var database: OpaquePointer?
    /// Core Data reference time (seconds since 2001) of the newest delivery seen; starts at "now" so history is skipped.
    private var watermark = Date().timeIntervalSinceReferenceDate
    private var seen: [Data] = []

    private struct Record {
        let uuid: Data
        let app: String
        let title: String
        let body: String
        let delivered: Double
    }

    private static var databasePath: String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 else { return nil }
        return String(cString: buffer) + "com.apple.notificationcenter/db2/db"
    }

    /// Called on every layout load: nil (no `mirror` in the layout) stops mirroring.
    func configure(_ options: NotificationMirrorOptions?) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.options = options
        guard options != nil else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let poll = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer = poll
        RunLoop.main.add(poll, forMode: .common)
    }

    private func poll() {
        guard let options = options else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            let records = self.readNewRecords()
            guard !records.isEmpty else { return }
            DispatchQueue.main.async {
                for record in records { self.post(title: record.title, body: record.body, app: record.app, options: options) }
            }
        }
    }

    func post(title: String, body: String, app: String, options: NotificationMirrorOptions) {
        let app = app.lowercased()
        guard !options.ignoreApps.contains(app) else { return }
        guard !title.isEmpty || !body.isEmpty else { return }
        let seconds = options.stickyApps.contains(app) ? options.stickySeconds : nil
        var title = title
        var body = body
        if options.lobApps.contains(app) {
            title = "lob"
            if body.range(of: "waiting for your input", options: .caseInsensitive) != nil { body = "lob is awaiting response" }
        }
        // Title and body: two lines (heading, then the body smaller). Only one of them: a single line.
        let twoLines = !title.isEmpty && !body.isEmpty
        _ = NotificationStore.shared.notify(text: twoLines ? body : title + body, seconds: seconds,
                                            icon: icon(for: app, options: options), title: twoLines ? title : nil)
    }

    private func icon(for app: String, options: NotificationMirrorOptions) -> NSImage? {
        // lob sessions notify through kitty: show the lob icon instead of kitty's.
        if options.lobApps.contains(app) { return lobIcon(size: TouchBarIcon.switcherBox) }
        return AppControlsApps.icon(app, size: TouchBarIcon.switcherBox)
    }

    // MARK: Database (mirror queue only)

    private func readNewRecords() -> [Record] {
        guard let database = openDatabase() else { return [] }
        let sql = "SELECT r.uuid, a.identifier, r.data, r.delivered_date FROM record r JOIN app a ON a.app_id = r.app_id WHERE r.delivered_date >= ? ORDER BY r.delivered_date"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            NSLog("MTMR mirror: query failed: %@", String(cString: sqlite3_errmsg(database)))
            closeDatabase()
            return []
        }
        defer { sqlite3_finalize(statement) }
        // A small overlap catches records whose delivery time equals the watermark; uuids remove the duplicates.
        sqlite3_bind_double(statement, 1, watermark - 2)
        var records: [Record] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let uuid = blob(statement, 0), !seen.contains(uuid) else { continue }
            let app = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let delivered = sqlite3_column_double(statement, 3)
            seen.append(uuid)
            watermark = max(watermark, delivered)
            guard let data = blob(statement, 2) else { continue }
            let (title, body) = Self.content(data)
            records.append(Record(uuid: uuid, app: app, title: title, body: body, delivered: delivered))
        }
        if seen.count > 500 { seen.removeFirst(seen.count - 500) }
        return records
    }

    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    /// The record's binary plist: req.titl / req.subt / req.body. Title and subtitle join with " · ".
    private static func content(_ data: Data) -> (title: String, body: String) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let request = plist["req"] as? [String: Any] else { return ("", "") }
        // Trimmed: kitty (OSC 99) sends a body of one space, which made a two-line entry with an empty text line.
        let trim = { (text: String?) in (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = [trim(request["titl"] as? String), trim(request["subt"] as? String)].filter { !$0.isEmpty }.joined(separator: " · ")
        return (title, trim(request["body"] as? String))
    }

    private func openDatabase() -> OpaquePointer? {
        if let database = database { return database }
        guard let path = Self.databasePath else { return nil }
        var handle: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            NSLog("MTMR mirror: cannot open the notification database")
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 200)
        database = handle
        return handle
    }

    private func closeDatabase() {
        sqlite3_close(database)
        database = nil
    }
}

/// The lob icon, drawn in code: a terminal prompt — orange ">_" — on a black tile (user's choice: orange and black).
func lobIcon(size: CGFloat) -> NSImage {
    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let tile = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let corner = tile.width * 0.24
        let shape = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
        NSGradient(starting: NSColor(white: 0.12, alpha: 1), ending: NSColor(white: 0.02, alpha: 1))?.draw(in: shape, angle: -90)
        // A faint edge keeps the dark tile visible on the black bar.
        NSColor(white: 1, alpha: 0.18).setStroke()
        shape.lineWidth = max(0.5, size * 0.02)
        shape.stroke()

        let stroke = max(1.2, size * 0.085)
        let left = tile.minX + tile.width * 0.24
        let tip = tile.minX + tile.width * 0.44
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: left, y: tile.midY + tile.height * 0.17))
        chevron.line(to: NSPoint(x: tip, y: tile.midY))
        chevron.line(to: NSPoint(x: left, y: tile.midY - tile.height * 0.17))
        chevron.lineWidth = stroke
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        let orange = NSColor(srgbRed: 1, green: 0.58, blue: 0.1, alpha: 1)
        orange.setStroke()
        chevron.stroke()

        let cursor = NSRect(x: tile.minX + tile.width * 0.5, y: tile.midY - tile.height * 0.17 - stroke / 2, width: tile.width * 0.26, height: stroke)
        orange.setFill()
        NSBezierPath(roundedRect: cursor, xRadius: stroke / 2, yRadius: stroke / 2).fill()
        return true
    }
}
