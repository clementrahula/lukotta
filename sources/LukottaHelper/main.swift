import Foundation
import LukottaCore
import SystemConfiguration

/// The privileged helper.
///
/// Runs as root under launchd so unlocking does not need an administrator
/// password every time. It accepts parameters, never a command: the script is
/// composed here, from the same builder the application uses.
final class HelperService: NSObject, NSXPCListenerDelegate, LukottaHelperProtocol {

    private let listener: NSXPCListener

    /// The running mount's output, so the app can show progress rather than
    /// sit on one step until everything is over.
    private let progressQueue = DispatchQueue(label: "dev.lukotta.helper.progress")
    private var transcript = ""
    /// Held only while a mount runs, so its output can be scrubbed of it.
    private var activeCredential: String?

    override init() {
        listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
        super.init()
        listener.delegate = self
    }

    func run() {
        if Self.signingTeam == nil {
            Log.helper.fault("unsigned or teamless build; every connection will be refused")
        }
        listener.resume()
        RunLoop.main.run()
    }

    // MARK: Accepting connections

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard isTrusted(connection) else {
            Log.helper.error("rejected a connection failing the code requirement")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: LukottaHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    /// Verify the peer really is Lukotta, signed by the expected team.
    ///
    /// Identified by process id. The audit token would be marginally stronger,
    /// being immune to pid reuse, but `NSXPCConnection.auditToken` is private
    /// API. The window for reuse here is the moment between a connection
    /// arriving and this check, with the peer already having had to know the
    /// mach service name.
    private func isTrusted(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
            let code
        else { return false }

        guard let text = HelperInfo.clientRequirement(team: Self.signingTeam ?? "") else {
            return false
        }

        var requirement: SecRequirement?
        guard
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement
        else { return false }

        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The team that signed this helper.
    ///
    /// Whoever built it is who its client has to be, which is what lets a fork
    /// signed with another certificate work without editing this file. Read
    /// once: it cannot change while the process is alive, and a daemon that
    /// re-read it per connection would only widen the window for surprises.
    private static let signingTeam: String? = {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }

        var still: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &still) == errSecSuccess, let still else { return nil }

        var info: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                still, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
            let signing = info as? [String: Any]
        else { return nil }

        return signing[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    // MARK: Work

    func mount(
        devicePath: String,
        aliasPath: String?,
        isLinux: Bool,
        volumeIdentifier: String?,
        credential: String,
        reply: @escaping (Int32, String) -> Void
    ) {
        mount(
            devicePath: devicePath, aliasPath: aliasPath, isLinux: isLinux,
            volumeIdentifier: volumeIdentifier, credential: credential,
            readOnly: false, reply: reply)
    }

    func mount(
        devicePath: String,
        aliasPath: String?,
        isLinux: Bool,
        volumeIdentifier: String?,
        credential: String,
        readOnly: Bool,
        reply: @escaping (Int32, String) -> Void
    ) {
        Log.helper.notice(
            "mount requested, linux \(isLinux, privacy: .public), read-only \(readOnly, privacy: .public)"
        )
        guard let engine = EnginePaths.anylinuxfs else {
            Log.helper.error("the mounting engine is missing")
            reply(70, "The mounting engine is missing.")
            return
        }
        do {
            let workspace = try Workspace()
            defer { workspace.destroy() }

            try EngineEnvironment.prepare { _ in }
            let fifo = try workspace.makeCredentialPipe()
            let log = workspace.root.appendingPathComponent("mount.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let expect = workspace.root.appendingPathComponent("discover.exp")
            try MountScript.expectDriver.write(to: expect, atomically: true, encoding: .utf8)

            let volume = volumeIdentifier.map {
                LogicalVolume(
                    identifier: $0.replacingOccurrences(of: "lvm:", with: ""),
                    label: "", filesystem: "", size: "")
            }
            let script = MountScript.build(
                MountScript.Inputs(
                    enginePath: engine.path,
                    devicePath: devicePath,
                    driveName: "",
                    kind: isLinux ? .linux : .microsoft,
                    volume: volume,
                    aliasPath: aliasPath,
                    fifoPath: fifo.path,
                    logPath: log.path,
                    discoverLogPath: workspace.root.appendingPathComponent("discover.log").path,
                    expectScriptPath: expect.path,
                    configPath: invokingHome() + "/.anylinuxfs/config.toml",
                    libraryPaths: EnginePaths.libraryPaths(),
                    uid: invokingUID(), gid: invokingGID(),
                    cores: MountScript.VirtualMachine.cores,
                    ramMiB: MountScript.VirtualMachine.ramMiB,
                    readOnly: readOnly))

            let scriptURL = workspace.root.appendingPathComponent("mount.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            progressQueue.sync {
                transcript = ""
                activeCredential = credential
            }
            defer { progressQueue.sync { activeCredential = nil } }
            let streamer = LogStreamer(path: log.path) { [weak self] line in
                self?.progressQueue.sync { self?.transcript += line + "\n" }
            }
            streamer.start()

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = [scriptURL.path]
            try task.run()

            // Hand the credential over once the script opens the pipe.
            DispatchQueue.global().async {
                if let handle = FileHandle(forWritingAtPath: fifo.path) {
                    handle.write(Data(credential.utf8))
                    try? handle.close()
                }
            }
            task.waitUntilExit()
            streamer.stop()

            var output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            // Always leave a trace. A failure whose log is empty gives the user
            // nothing to report and us nothing to read; the exit status alone
            // says whether the script ran at all and how far it got.
            output +=
                "\nmount script exited with status \(task.terminationStatus)"
                + " for \(devicePath)"
            Log.helper.notice(
                "mount script exited \(task.terminationStatus, privacy: .public)")
            reply(task.terminationStatus, Diagnostics.redact(output, secret: credential))
        } catch {
            Log.helper.error("the mount could not be run: \(error)")
            reply(71, "\(error)")
        }
    }

    func progress(reply: @escaping (String) -> Void) {
        let (text, secret) = progressQueue.sync { (transcript, activeCredential) }
        reply(Diagnostics.redact(text, secret: secret))
    }

    func identify(devicePath: String, reply: @escaping (String) -> Void) {
        guard let sector = BootSector.read(devicePath: devicePath) else {
            Log.helper.notice("could not read the first sector")
            reply(VolumeFormat.unknown.rawValue)
            return
        }
        let format = BootSector.identify(sector)
        Log.helper.notice("partition identified as \(format.rawValue, privacy: .public)")
        reply(format.rawValue)
    }

    func unmount(mountPoint: String, reply: @escaping (Int32, String) -> Void) {
        let result = EngineStatus.unmount(mountPoint: mountPoint)
        Log.helper.notice("unmount succeeded: \(result.ok, privacy: .public)")
        reply(result.ok ? 0 : 1, result.message)
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }

    /// The console user, whose home the engine resolves paths against.
    private func invokingUID() -> UInt32 {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) {
            _ = name
        }
        return uid == 0 ? 501 : uid
    }

    private func invokingGID() -> UInt32 {
        var uid: uid_t = 0
        var gid: gid_t = 0
        if let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) {
            _ = name
        }
        return gid == 0 ? 20 : gid
    }

    /// The console user's home, where the engine keeps its config.toml. The
    /// helper runs as root, so NSHomeDirectory would answer /var/root — a
    /// config there is one the engine, resolving against SUDO_UID, never reads.
    private func invokingHome() -> String {
        if let entry = getpwuid(invokingUID()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return "/Users/Shared"
    }
}

HelperService().run()
