import Foundation

/// A bug-report summary of how well the Notes database decodes. Counts only: no titles, text, tags or folder names,
/// so it is safe to paste into a public issue.
enum Diagnostics {
    static var appVersion: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "dev") (\(i?["CFBundleVersion"] as? String ?? "0"))"
    }

    static func report() -> String {
        var lines = ["App: \(appVersion)",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Full Disk Access: \(NotesReader.hasAccess ? "yes" : "no")"]
        defer { lines.append("") }
        do {
            let start = Date()
            let reader = try NotesReader()
            let uuid = try reader.storeUUID()
            let stamps = try reader.stamps()
            let tags = try reader.hashtags()
            let alt = try reader.inlineAltText()
            let raws = try reader.notes(Array(stamps.keys))

            var locked = 0, noData = 0, failed = 0, empty = 0, attachments = 0
            var styles: [Int: Int] = [:], failHeads: [String: Int] = [:]
            for r in raws {
                if r.locked { locked += 1; continue }
                guard let data = r.data else { noData += 1; continue }
                guard let spans = NoteDecoder.spans(from: data, altText: alt) else {
                    failed += 1
                    let gz = NoteDecoder.gunzip([UInt8](data))
                    let head = data.prefix(2).map { String(format: "%02x", $0) }.joined()
                    failHeads["\(head) \(data.count)B gunzip=\(gz.map { "\($0.count)B" } ?? "fail")", default: 0] += 1
                    continue
                }
                if spans.allSatisfy({ $0.text.isEmpty }) { empty += 1 }
                for s in spans {
                    if s.style.attachment { attachments += 1 }
                    if s.style.paragraph >= 0 { styles[s.style.paragraph, default: 0] += 1 }
                }
            }
            lines += [
                "Store UUID well-formed: \(!uuid.isEmpty && uuid.allSatisfy { $0.isHexDigit || $0 == "-" })",
                "Notes (excluding deleted): \(stamps.count), rows read: \(raws.count)",
                "Folders: \(Set(stamps.values.map(\.folder)).count)",
                "Locked: \(locked), no body: \(noData), decode failed: \(failed), empty: \(empty)",
                "Attachments: \(attachments), notes with hashtags: \(tags.count), distinct hashtags: \(Set(tags.values.joined()).count)",
                "Decode failures (header, size, gunzip): " + (failHeads.isEmpty ? "none" : failHeads.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: "; ")),
                "Paragraph styles: " + styles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "),
                "Read + decode time: \(Int(Date().timeIntervalSince(start) * 1000)) ms",
            ]
        } catch {
            lines.append("Error: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }
}
