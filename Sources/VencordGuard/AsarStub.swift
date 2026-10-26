import Foundation

/// Byte-for-byte port of the official Vencord Installer's `WriteAppAsar`
/// (https://github.com/Vencord/Installer/blob/main/app_asar.go), which is itself a port of
/// asar-cr's packer. Keeping the exact byte layout matters: it is what makes an install
/// written by this guard indistinguishable from one written by VencordInstaller.app, so the
/// official installer can still repair, uninstall, or upgrade on top of it.
enum AsarStub {

    /// Exactly the Go `PackageJson` raw string literal (43 bytes).
    static let packageJSON = "{\n\t\"name\": \"discord\",\n\t\"main\": \"index.js\"\n}"

    static func indexJS(patcherPath: String) -> String {
        // Go does json.Marshal on the path, which is the same escaping as a JSON string literal.
        let quoted = jsonQuote(patcherPath)
        return "require(\(quoted))"
    }

    static func build(patcherPath: String) -> Data {
        let index = indexJS(patcherPath: patcherPath)
        let indexBytes = index.utf8.count
        let pkgBytes = packageJSON.utf8.count

        // Go marshals map[string]... with keys sorted; "index.js" < "package.json".
        // Struct field order is size then offset. Built literally so the bytes cannot drift.
        let header = "{\"files\":{"
            + "\"index.js\":{\"size\":\(indexBytes),\"offset\":\"0\"},"
            + "\"package.json\":{\"size\":\(pkgBytes),\"offset\":\"\(indexBytes)\"}"
            + "}}"

        let headerStringSize = UInt32(header.utf8.count)
        let dataSize: UInt32 = 4
        let alignedSize = (headerStringSize + dataSize - 1) & ~(dataSize - 1)
        let headerSize = alignedSize + 8
        let headerObjectSize = alignedSize + dataSize
        let padding = String(repeating: "0", count: Int(alignedSize - headerStringSize))

        var out = Data()
        for n in [dataSize, headerSize, headerObjectSize, headerStringSize] {
            var le = n.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: Array((header + padding).utf8))
        out.append(contentsOf: Array((index + packageJSON).utf8))
        return out
    }

    /// True when `data` is the Vencord stub asar pointing at `patcherPath`.
    /// Cheap enough to run on every Discord launch: the stub is ~220 bytes.
    static func isStub(data: Data, patcherPath: String) -> Bool {
        guard data.count < 4096, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(indexJS(patcherPath: patcherPath))
    }

    /// True when `data` looks like *some* asar stub that requires an external patcher —
    /// i.e. a client mod is installed, but not the one we manage.
    static func isForeignStub(data: Data) -> Bool {
        guard data.count < 4096, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("require(")
    }

    private static func jsonQuote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
