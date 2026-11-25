import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Your files, for agents: found with Spotlight and read as text, in your
/// everyday folders only (AgentCommands.everydayFolders), never hidden ones.
/// So "upload my latest invoice to this form" or "fill this in from my CV"
/// needs no Finder: find it, read it, page_upload it.
enum Files {
    /// Spotlight's matches for `query` (its own syntax: words, "kind:pdf",
    /// "date:today"), names first, then the most lately changed. With no
    /// query: what changed in the last two weeks, newest first.
    static func find(_ query: String, limit: Int) async throws -> [[String: Any]] {
        let folders = AgentCommands.everydayFolders
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // One Spotlight query per folder, all at once.
        let paths: [String] = try await withThrowingTaskGroup(of: [String].self) { group in
            for folder in folders {
                let arguments = trimmed.isEmpty
                    ? ["-onlyin", folder, "kMDItemFSContentChangeDate >= $time.today(-14) && kMDItemContentType != public.folder"]
                    : ["-onlyin", folder, trimmed]
                group.addTask { try await run("/usr/bin/mdfind", arguments).split(separator: "\n").map(String.init) }
            }
            var all: [String] = []
            for try await some in group { all += some }
            return all
        }
        let words = trimmed.lowercased().split(separator: " ").filter { !$0.contains(":") }.map(String.init)
        let manager = FileManager.default
        var seen = Set<String>()
        var found: [(path: String, name: String, modified: Date, size: Int, folder: Bool, named: Bool)] = []
        for path in paths where seen.insert(path).inserted {
            let parts = path.split(separator: "/")
            // Not hidden, not inside an app or a package's insides, not a project's dependencies.
            if parts.contains(where: { $0.hasPrefix(".") || $0 == "node_modules" || $0.hasSuffix(".app") && $0 != parts.last }) { continue }
            guard let attributes = try? manager.attributesOfItem(atPath: path) else { continue }
            let name = (path as NSString).lastPathComponent
            let lower = name.lowercased()
            found.append((path, name, attributes[.modificationDate] as? Date ?? .distantPast,
                          (attributes[.size] as? NSNumber)?.intValue ?? 0, attributes[.type] as? FileAttributeType == .typeDirectory,
                          !words.isEmpty && words.allSatisfy { lower.contains($0) }))
        }
        found.sort { $0.named != $1.named ? $0.named : $0.modified > $1.modified }
        let home = NSHomeDirectory()
        return found.prefix(limit).map { item in
            var out: [String: Any] = ["path": item.path, "name": item.name,
                                      "where": item.path.hasPrefix(home) ? "~" + item.path.dropFirst(home.count) : item.path,
                                      "modified": ISO8601DateFormatter().string(from: item.modified)]
            if item.folder { out["folder"] = true } else {
                out["size"] = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
                out["kind"] = UTType(filenameExtension: (item.name as NSString).pathExtension)?.localizedDescription ?? ""
            }
            return out
        }
    }

    /// A file as text: plain text, PDF, Word, RTF, HTML, Pages' preview; a
    /// folder's list of files; an image's size.
    static func read(_ path: String, maxChars: Int) async throws -> [String: Any] {
        let url = URL(fileURLWithPath: path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { throw AgentError("No file at \(path).") }
        if isFolder.boolValue && url.pathExtension.isEmpty {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path))?.filter { !$0.hasPrefix(".") }.sorted() ?? []
            return ["path": path, "folder": true, "files": Array(names.prefix(300))]
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw AgentError("Couldn't open the PDF.") }
            text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        } else if type?.conforms(to: .image) == true {
            let size = NSImage(contentsOf: url)?.size ?? .zero
            return ["path": path, "kind": type?.localizedDescription ?? "image", "width": Int(size.width), "height": Int(size.height),
                    "note": "An image: upload it with page_upload; its pixels aren't read here."]
        } else if ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive", "wordml"].contains(url.pathExtension.lowercased()) {
            let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
            text = attributed.string
        } else if ["pages", "numbers", "key"].contains(url.pathExtension.lowercased()) {
            // iWork files keep a PDF preview inside.
            let preview = url.appendingPathComponent("QuickLook/Preview.pdf")
            guard let document = PDFDocument(url: preview) else { throw AgentError("Couldn't read this \(url.pathExtension) file: export it as PDF first.") }
            text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n\n")
        } else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard let decoded = String(data: data.prefix(maxChars * 4), encoding: .utf8) ?? String(data: data.prefix(maxChars * 4), encoding: .isoLatin1),
                  !decoded.contains("\u{0}") else {
                throw AgentError("Not a text file (\(type?.localizedDescription ?? url.pathExtension)). Upload it with page_upload instead.")
            }
            text = decoded
        }
        return ["path": path, "kind": type?.localizedDescription ?? url.pathExtension, "chars": text.count,
                "text": String(text.prefix(maxChars)), "truncated": text.count > maxChars]
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
