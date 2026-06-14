import Foundation
import Testing
@testable import Pilot

@Suite("Local server scanner")
struct LocalServerScannerTests {

    // Builds a throwaway workspace on disk and returns its root path.
    private func makeFixture(_ build: (URL) throws -> Void) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root.path
    }

    private func writeApp(in root: URL, name: String, devScript: String, wranglerPort: Int?) throws {
        let dir = root.appendingPathComponent("workers/\(name)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `next` is in deps on purpose — the old scanner inferred 3000 from it.
        let pkg = """
        { "name": "\(name)", "scripts": { "dev": "\(devScript)" }, "dependencies": { "next": "15.0.0" } }
        """
        try pkg.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        if let wranglerPort {
            // jsonc with a comment + trailing inspector_port, mirroring real
            // wrangler.jsonc files, to exercise the tolerant regex.
            let wrangler = """
            {
              // wrangler config
              "name": "\(name)",
              "dev": { "port": \(wranglerPort), "inspector_port": \(wranglerPort + 500) }
            }
            """
            try wrangler.write(to: dir.appendingPathComponent("wrangler.jsonc"), atomically: true, encoding: .utf8)
        }
    }

    /// Regression for the "all cards say jb-gear / localhost:3000" bug: wrangler
    /// (`next`-on-Cloudflare) apps must report their wrangler `[dev].port`, not
    /// the next-default 3000 that previously collapsed every app onto one port.
    @Test
    func wranglerAppsReportTheirDevPortNotTheNextDefault() async throws {
        let root = try makeFixture { root in
            try writeApp(in: root, name: "jb-www",    devScript: "wrangler dev", wranglerPort: 33000)
            try writeApp(in: root, name: "jb-travel", devScript: "wrangler dev", wranglerPort: 33001)
            try writeApp(in: root, name: "jb-gear",   devScript: "wrangler dev", wranglerPort: 33002)
            try writeApp(in: root, name: "jb-swap",   devScript: "wrangler dev", wranglerPort: 33003)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let servers = await LocalServerScanner.scan(rootPath: root)
        let byName = Dictionary(servers.map { ($0.name, $0.port) }, uniquingKeysWith: { a, _ in a })

        #expect(byName["jb-www"] == 33000)
        #expect(byName["jb-travel"] == 33001)
        #expect(byName["jb-gear"] == 33002)
        #expect(byName["jb-swap"] == 33003)
        // Four distinct ports => four distinct ForEach identities (no collapse).
        #expect(Set(servers.map(\.id)).count == 4)
    }

    /// `wrangler dev` with no configured `[dev].port` falls back to wrangler's
    /// own default (8787), not the framework default.
    @Test
    func wranglerWithoutDevPortFallsBackTo8787() async throws {
        let root = try makeFixture { root in
            try writeApp(in: root, name: "edge", devScript: "wrangler dev", wranglerPort: nil)
        }
        defer { try? FileManager.default.removeItem(atPath: root) }

        let servers = await LocalServerScanner.scan(rootPath: root)
        #expect(servers.first?.port == 8787)
    }

    /// Two dev servers on the same port must keep distinct identities, otherwise
    /// `ForEach(id:)` renders one of them N times (the proximate cause of the
    /// repeated "jb-gear" cards).
    @Test
    func samePortDifferentNamesStayDistinctlyIdentified() {
        let alpha = LocalServer(port: 3000, name: "alpha")
        let beta = LocalServer(port: 3000, name: "beta")
        #expect(alpha.id != beta.id)
    }
}
