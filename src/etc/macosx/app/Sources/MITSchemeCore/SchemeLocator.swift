import Foundation

public enum SchemeLaunchMode: Equatable, Sendable {
    case repl
    case edwin(fileURL: URL? = nil)
}

public struct SchemeLaunchConfig: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let sourceDescription: String

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        sourceDescription: String
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.sourceDescription = sourceDescription
    }
}

public enum SchemeLocatorError: LocalizedError, Sendable {
    case executableNotFound([String])

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(searched):
            return "Unable to locate a native mit-scheme executable. Checked: \(searched.joined(separator: ", "))"
        }
    }
}

public enum SchemeLocator {
    public static func resolve(
        mode: SchemeLaunchMode,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) throws -> SchemeLaunchConfig {
        let fm = FileManager.default
        var searched: [String] = []
        var launchEnv = sanitizedEnvironment(from: environment)

        func buildArgs(useMacApp: Bool, libraryDir: URL?, band: String?) -> [String] {
            var args: [String] = []
            if useMacApp {
                args.append("--macosx-application")
            } else {
                if let libraryDir {
                    args.append(contentsOf: ["--library", libraryDir.path])
                }
                if let band {
                    args.append(contentsOf: ["--band", band])
                }
            }
            switch mode {
            case .repl:
                break
            case let .edwin(fileURL):
                args.append("--edit")
                if let fileURL {
                    args.append(fileURL.path)
                }
            }
            return args
        }

        // 1. Explicit override via MIT_SCHEME_APP_EXE (used by CI & local development tests).
        if let rawExe = environment["MIT_SCHEME_APP_EXE"], !rawExe.isEmpty {
            let exeURL = URL(fileURLWithPath: rawExe)
            searched.append(exeURL.path)
            if fm.isExecutableFile(atPath: exeURL.path) {
                let rawLib = environment["MIT_SCHEME_APP_LIBRARY"]
                let rawBand = environment["MIT_SCHEME_APP_BAND"]
                let resDir = exeURL.deletingLastPathComponent()
                let isAppBundle = fm.fileExists(atPath: resDir.appendingPathComponent("all.com").path)
                    && fm.fileExists(atPath: resDir.deletingLastPathComponent().appendingPathComponent("Info.plist").path)
                    && (rawLib == nil || rawLib?.isEmpty == true)

                if isAppBundle {
                    launchEnv.removeValue(forKey: "MITSCHEME_LIBRARY_PATH")
                    return SchemeLaunchConfig(
                        executableURL: exeURL,
                        arguments: buildArgs(useMacApp: true, libraryDir: nil, band: rawBand),
                        environment: launchEnv,
                        workingDirectory: defaultWorkingDirectory(from: environment, fallback: currentDirectoryURL),
                        sourceDescription: "Override Bundle (\(exeURL.lastPathComponent))"
                    )
                }

                let libURL = rawLib.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                let band = rawBand?.isEmpty == false ? rawBand : (libURL != nil ? "all.com" : nil)
                return SchemeLaunchConfig(
                    executableURL: exeURL,
                    arguments: buildArgs(useMacApp: false, libraryDir: libURL, band: band),
                    environment: launchEnv,
                    workingDirectory: defaultWorkingDirectory(from: environment, fallback: currentDirectoryURL),
                    sourceDescription: "Override (\(exeURL.path))"
                )
            }
        }

        // 2. Bundled application Resources/mit-scheme + Resources/all.com.
        if let resourceURL = bundle.resourceURL {
            let bundledExe = resourceURL.appendingPathComponent("mit-scheme")
            let bundledBand = resourceURL.appendingPathComponent("all.com")
            searched.append(bundledExe.path)
            if fm.isExecutableFile(atPath: bundledExe.path) && fm.fileExists(atPath: bundledBand.path) {
                launchEnv.removeValue(forKey: "MITSCHEME_LIBRARY_PATH")
                return SchemeLaunchConfig(
                    executableURL: bundledExe,
                    arguments: buildArgs(useMacApp: true, libraryDir: nil, band: nil),
                    environment: launchEnv,
                    workingDirectory: fm.homeDirectoryForCurrentUser,
                    sourceDescription: "Bundled MIT/GNU Scheme"
                )
            }
        }

        // 3. Development tree fallback (walking up to zig-out/bin/mit-scheme or src/microcode/scheme + src/lib/all.com).
        let searchRoots = [currentDirectoryURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()]
            .compactMap { $0 }
        for root in searchRoots {
            var dir = root.standardizedFileURL
            for _ in 0..<8 {
                let devLib = dir.appendingPathComponent("src/lib", isDirectory: true)
                let devBand = devLib.appendingPathComponent("all.com")
                for relExe in ["zig-out/bin/mit-scheme", "src/microcode/scheme"] {
                    let devExe = dir.appendingPathComponent(relExe)
                    searched.append(devExe.path)
                    if fm.isExecutableFile(atPath: devExe.path) && fm.fileExists(atPath: devBand.path) {
                        return SchemeLaunchConfig(
                            executableURL: devExe,
                            arguments: buildArgs(useMacApp: false, libraryDir: devLib, band: "all.com"),
                            environment: launchEnv,
                            workingDirectory: dir,
                            sourceDescription: "Workspace Build (\(devExe.path))"
                        )
                    }
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path {
                    break
                }
                dir = parent
            }
        }

        // 4. PATH / standard system installation fallback.
        var pathCandidates = ["/usr/local/bin/mit-scheme", "/opt/homebrew/bin/mit-scheme"]
        if let pathEnv = environment["PATH"] {
            for component in pathEnv.split(separator: ":") {
                pathCandidates.append(String(component) + "/mit-scheme")
            }
        }
        var seen = Set<String>()
        for candidate in pathCandidates where seen.insert(candidate).inserted {
            searched.append(candidate)
            if fm.isExecutableFile(atPath: candidate) {
                return SchemeLaunchConfig(
                    executableURL: URL(fileURLWithPath: candidate),
                    arguments: buildArgs(useMacApp: false, libraryDir: nil, band: nil),
                    environment: launchEnv,
                    workingDirectory: defaultWorkingDirectory(from: environment, fallback: currentDirectoryURL),
                    sourceDescription: "System (\(candidate))"
                )
            }
        }

        throw SchemeLocatorError.executableNotFound(searched)
    }

    private static func defaultWorkingDirectory(
        from env: [String: String],
        fallback: URL
    ) -> URL {
        if let home = env["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return fallback
    }

    private static func sanitizedEnvironment(from env: [String: String]) -> [String: String] {
        var result = env
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        if result["LANG"] == nil {
            result["LANG"] = "en_US.UTF-8"
        }
        return result
    }
}
