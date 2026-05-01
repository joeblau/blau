import Foundation

struct LocalServer: Identifiable, Hashable, Sendable {
    let port: Int
    let name: String

    var id: Int { port }
    var url: URL { URL(string: "http://localhost:\(port)")! }
    var displayURL: String { "localhost:\(port)" }
}

// LocalServerScanner — best-effort discovery of dev-server candidates for a
// workspace. Scans the project tree for `package.json`, framework configs,
// and `.env*` files; pulls out an explicit port when present and otherwise
// falls back to the framework's default (Next: 3000, Vite: 5173, etc.).
//
// Only candidates are returned — liveness is determined separately by
// `LocalServerProbe`.
enum LocalServerScanner {
    private static let maxDepth = 4

    private static let ignoredDirectories: Set<String> = [
        "node_modules", ".git", "dist", "build", "target", ".next", ".nuxt",
        ".svelte-kit", "vendor", "DerivedData", ".build", "Pods", "out",
        ".turbo", ".cache", "coverage", ".vercel"
    ]

    static func scan(rootPath: String) async -> [LocalServer] {
        guard !rootPath.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            collect(rootPath: rootPath)
        }.value
    }

    private static func collect(rootPath: String) -> [LocalServer] {
        let root = URL(fileURLWithPath: rootPath)
        let configFiles = collectConfigFiles(at: root)

        var byPort: [Int: LocalServer] = [:]
        for url in configFiles {
            guard let server = parse(file: url) else { continue }
            // First write wins so the more specific source (package.json) is
            // preferred over an `.env` fallback at the same project root.
            if byPort[server.port] == nil {
                byPort[server.port] = server
            }
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    // MARK: - Tree walk

    private static func collectConfigFiles(at root: URL) -> [URL] {
        var result: [URL] = []
        var queue: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default

        while let (dir, depth) = queue.first {
            queue.removeFirst()
            if depth > maxDepth { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { continue }

            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let name = entry.lastPathComponent
                if isDir {
                    if !ignoredDirectories.contains(name), !name.hasPrefix(".") || name == ".env" {
                        queue.append((entry, depth + 1))
                    }
                } else if name == "package.json" || name.hasPrefix(".env") {
                    result.append(entry)
                }
            }
        }
        return result
    }

    // MARK: - Per-file parsers

    private static func parse(file: URL) -> LocalServer? {
        let name = file.lastPathComponent
        if name == "package.json" {
            return parsePackageJSON(at: file)
        }
        if name.hasPrefix(".env") {
            let projectName = file.deletingLastPathComponent().lastPathComponent
            return parseEnv(at: file, fallbackName: projectName)
        }
        return nil
    }

    private static func parsePackageJSON(at url: URL) -> LocalServer? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let projectName = displayName(
            packageName: json["name"] as? String,
            folder: url.deletingLastPathComponent().lastPathComponent
        )
        let scripts = json["scripts"] as? [String: String] ?? [:]
        let scriptValue = ["dev", "start", "serve"]
            .compactMap { scripts[$0] }
            .first ?? ""

        if let port = extractPort(fromScript: scriptValue) {
            return LocalServer(port: port, name: projectName)
        }
        if let port = inferFrameworkPort(script: scriptValue, packageJSON: json) {
            return LocalServer(port: port, name: projectName)
        }
        return nil
    }

    private static func parseEnv(at url: URL, fallbackName: String) -> LocalServer? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for rawLine in content.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("PORT=") || line.hasPrefix("PORT =") else { continue }
            let value = line
                .drop(while: { $0 != "=" })
                .dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if let port = Int(value) {
                return LocalServer(port: port, name: fallbackName)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func displayName(packageName: String?, folder: String) -> String {
        guard let raw = packageName, !raw.isEmpty else { return folder }
        // Strip @scope/ prefixes so "@blau/web" → "web"
        if raw.hasPrefix("@"), let slash = raw.firstIndex(of: "/") {
            return String(raw[raw.index(after: slash)...])
        }
        return raw
    }

    private static func extractPort(fromScript script: String) -> Int? {
        // Matches `--port 3000`, `--port=3000`, `-p 3000`, `-p=3000`.
        let pattern = #"(?:--port|-p)[\s=]+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(script.startIndex..., in: script)
        guard let match = regex.firstMatch(in: script, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: script) else { return nil }
        return Int(script[r])
    }

    private static func inferFrameworkPort(script: String, packageJSON: [String: Any]) -> Int? {
        let lower = script.lowercased()
        if lower.contains("next") { return 3000 }
        if lower.contains("vite") { return 5173 }
        if lower.contains("astro") { return 4321 }
        if lower.contains("react-scripts") { return 3000 }
        if lower.contains("ng serve") || lower.contains("ng start") { return 4200 }
        if lower.contains("gatsby") { return 8000 }
        if lower.contains("nuxt") { return 3000 }
        if lower.contains("remix") { return 3000 }

        let deps = (packageJSON["dependencies"] as? [String: Any]) ?? [:]
        let devDeps = (packageJSON["devDependencies"] as? [String: Any]) ?? [:]
        let merged = deps.merging(devDeps) { lhs, _ in lhs }
        if merged["next"] != nil { return 3000 }
        if merged["vite"] != nil { return 5173 }
        if merged["astro"] != nil { return 4321 }
        if merged["react-scripts"] != nil { return 3000 }
        if merged["@angular/cli"] != nil { return 4200 }
        if merged["gatsby"] != nil { return 8000 }
        if merged["nuxt"] != nil || merged["nuxt3"] != nil { return 3000 }
        if merged["@remix-run/dev"] != nil { return 3000 }
        return nil
    }
}
