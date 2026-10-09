import Foundation
import Darwin

/// What `read_file` returns for a directory (#337): its entries one level deep, sorted, a trailing
/// `/` on each directory, every name on one line, and the whole capped in bytes. Read from an open
/// descriptor, so the grader's walk (`GrantedFileAccess`) lists exactly the directory it opened.
enum DirectoryListing {
    struct Entry: Equatable {
        let name: String
        let isDirectory: Bool
    }

    /// Caps the entry lines, not the header or the trailer.
    static let maxBytes = 16_384

    /// The entries of the directory `fd` refers to, `.` and `..` left out. A symlink is reported
    /// as itself, never followed: a link to a directory gets no `/`. `fd` stays the caller's.
    static func entries(ofDirectory fd: Int32) throws -> [Entry] {
        let own = dup(fd)
        guard own >= 0 else { throw GrantedFileError.io(call: "dup", errno: errno) }
        guard let dir = fdopendir(own) else {
            let code = errno
            close(own)
            throw GrantedFileError.io(call: "fdopendir", errno: code)
        }
        defer { closedir(dir) }
        // The dup shares the parent's offset; a descriptor read before would start mid-stream.
        rewinddir(dir)
        var result: [Entry] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var type = entry.pointee.d_type
            if type == UInt8(DT_UNKNOWN) {
                var st = stat()
                let isDir = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    raw.withMemoryRebound(to: CChar.self) { fstatat(dirfd(dir), $0.baseAddress!, &st, AT_SYMLINK_NOFOLLOW) }
                } == 0 && (st.st_mode & S_IFMT) == S_IFDIR
                type = isDir ? UInt8(DT_DIR) : UInt8(DT_REG)
            }
            result.append(Entry(name: name, isDirectory: type == UInt8(DT_DIR)))
        }
        return result
    }

    static func list(directory fd: Int32, maxBytes: Int = maxBytes) throws -> String {
        format(try entries(ofDirectory: fd), maxBytes: maxBytes)
    }

    static func format(_ entries: [Entry], maxBytes: Int = maxBytes) -> String {
        let lines = entries.sorted { $0.name < $1.name }
            .map { flatten($0.name) + ($0.isDirectory ? "/" : "") }
        var out = "Directory listing: \(lines.count) \(lines.count == 1 ? "entry" : "entries"); directories end in `/`; control characters in names are escaped.\n"
        if lines.isEmpty { return out + "(empty)" }
        var used = 0
        var shown = 0
        for line in lines {
            let cost = line.utf8.count + 1
            if used + cost > maxBytes { break }
            out += line + "\n"
            used += cost
            shown += 1
        }
        if shown < lines.count {
            out += "… \(lines.count - shown) more not shown (listing capped at \(maxBytes) bytes)\n"
        }
        return out
    }

    /// One name, one line: a newline in a filename would otherwise forge a second entry. Control,
    /// format and line/paragraph separator scalars are escaped as `\u{…}` (`\n`, `\r`, `\t` by
    /// their usual names), and a backslash is doubled so an escape cannot be spelled by a name.
    static func flatten(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator:
                    out += "\\u{\(String(scalar.value, radix: 16))}"
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
