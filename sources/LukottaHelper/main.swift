// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

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
    private let progressQueue = DispatchQueue(label: "com.lukotta.helper.progress")

    /// One mount's output and the credential to keep out of it.
    ///
    /// Kept together, and only ever replaced as a pair. They were two variables
    /// on this object: a second mount starting while the first ran overwrote
    /// the credential and appended to the same transcript, and the first one
    /// finishing set the credential to nil while the second was still going. A
    /// passphrase is taken out of the output *by value*, so the window where
    /// the wrong value is held is the window where a passphrase the engine
    /// echoed reaches the app relying on pattern matching alone.
    private struct Running {
        var transcript = ""
        var credential: String?
    }

    /// The mounts running now, by the workspace that is serving each. The
    /// engine allows one at a time, so this is usually one -- and "usually" is
    /// not something to hold a passphrase with.
    private var running: [String: Running] = [:]

    /// Everything running, oldest first, for the app's progress request. The
    /// app asks for "the mount", because from where it stands there is one.
    private func transcriptForProgress() -> (String, String?) {
        let all = running.keys.sorted().compactMap { running[$0] }
        let text = all.map(\.transcript).joined()
        // Scrubbed against every credential in flight, not whichever was set
        // last: what has to be removed is all of them.
        let secrets = all.compactMap(\.credential)
        return (text, secrets.first)
    }

    /// Who the connected app runs as, recorded when the connection is accepted.
    ///
    /// The helper runs as root and has no user of its own. Everything it does
    /// on somebody's behalf — the engine's home, its config, the ownership the
    /// mount is exported with — belongs to the account running the app, and the
    /// connection is the only thing that says which account that is.
    private var peerUID: uid_t?
    private var peerGID: gid_t?

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
        // Who the app is running as. This is the user whose drive is being
        // opened and whose home the engine resolves its paths against, and it
        // is the only answer that is right for a second user or for anybody
        // whose account is not the first one on the Mac.
        peerUID = connection.effectiveUserIdentifier
        peerGID = connection.effectiveGroupIdentifier
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
    /// Where the application that is asking keeps the engine.
    ///
    /// The daemon cannot find it in its own bundle, because it has not got
    /// one: SMJobBless installs it as a bare binary in
    /// /Library/PrivilegedHelperTools, and `Bundle.main.resourceURL` there
    /// points at a directory with nothing in it. Every mount through the
    /// helper therefore answered "the mounting engine is missing" -- a daemon
    /// that installs, connects, is trusted, and cannot do the one thing it is
    /// for.
    ///
    /// Taken from the caller, and from the caller's signature rather than from
    /// anything it says: this is the same code object `isTrusted` has just
    /// checked against the requirement, so the path is one macOS resolved for
    /// a bundle signed by the team that signed this daemon. A path sent over
    /// the connection would be a string from a client, and root would be
    /// following it.
    private func engineOfTheCaller(_ connection: NSXPCConnection) -> URL? {
        let attributes =
            [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var still: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &still) == errSecSuccess, let still else {
            return nil
        }
        var path: CFURL?
        guard SecCodeCopyPath(still, [], &path) == errSecSuccess,
            let bundle = path as URL?
        else { return nil }

        let engine =
            bundle
            .appendingPathComponent("Contents/Resources/engine/anylinuxfs/bin/anylinuxfs")
        return FileManager.default.fileExists(atPath: engine.path) ? engine : nil
    }

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
        // This daemon's own bundle first, which is where a helper running from
        // inside the application finds it, and the caller's otherwise: a
        // helper installed by SMJobBless is a bare binary in
        // /Library/PrivilegedHelperTools with no resources of its own.
        let engineOfMine = EnginePaths.anylinuxfs.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        }
        guard
            let engine = engineOfMine
                ?? NSXPCConnection.current().flatMap({ self.engineOfTheCaller($0) })
        else {
            Log.helper.error("the mounting engine is missing")
            reply(70, "The mounting engine is missing.")
            return
        }
        // So that the library paths, the Alpine image and the record of which
        // patches were applied all come from the same place the binary did.
        EnginePaths.useEngine(
            at: engine.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent())
        Log.helper.notice(
            "engine at \(EnginePaths.engineRoot?.path ?? "nowhere", privacy: .public)")
        // Refused rather than guessed at. Everything below is composed against
        // somebody's home directory, and building it against root's — or
        // against whichever account happens to be first on this Mac — either
        // fails or quietly uses a stranger's settings.
        guard hasAnInvokingUser(), let userHome = invokingHome() else {
            Log.helper.error("no user to mount for; refusing")
            reply(71, "Could not tell which user this is for.")
            return
        }
        do {
            let workspace = try Workspace()
            defer { workspace.destroy() }

            // Into the invoking user's directory, not root's. This process is
            // root, so anything it resolves from its own home lands in
            // /var/root -- a hundred megabytes unpacked where nothing will ever
            // look for it, while the script written below points somewhere
            // else entirely and the mount finds no environment at all.
            //
            // Composed once, and the two names are kept apart on purpose. This
            // used to shadow the user's home with the engine's, and the two
            // uses further down composed the already-composed path a second
            // time: the engine was handed
            //   ~/Library/Application Support/<id>/engine
            //     /Library/Application Support/<id>/engine
            // It creates that directory, because it creates whatever
            // ANYLINUXFS_HOME names -- and then cannot open its log inside it,
            // because on macOS it does not create the log directory. Every
            // mount through this daemon failed with "Failed to create log file:
            // No such file or directory", which says nothing about any of that.
            let stateHome = engineHome(of: userHome)
            try EngineEnvironment.prepare(
                into: URL(fileURLWithPath: stateHome).appendingPathComponent(
                    ".anylinuxfs/alpine", isDirectory: true)
            ) { _ in }
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
                    configPath: stateHome + "/.anylinuxfs/config.toml",
                    engineHome: stateHome,
                    libraryPaths: EnginePaths.libraryPaths(),
                    uid: invokingUID(), gid: invokingGID(),
                    cores: MountScript.VirtualMachine.cores,
                    ramMiB: MountScript.VirtualMachine.ramMiB,
                    readOnly: readOnly))

            let scriptURL = workspace.root.appendingPathComponent("mount.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            // This mount's own slot, named by the workspace that serves it, so
            // two mounts cannot write over each other's output or credential.
            let token = workspace.root.lastPathComponent
            progressQueue.sync { running[token] = Running(credential: credential) }
            defer { progressQueue.sync { running[token] = nil } }
            let streamer = LogStreamer(path: log.path) { [weak self] line in
                self?.progressQueue.sync { self?.running[token]?.transcript += line + "\n" }
            }
            streamer.start()

            // What was running before this attempt, so that what it starts can
            // be told from what is serving drives somebody has open.
            let helpersBefore = EngineProcesses.running()

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

            // Waited for, but not for ever -- the same deadline the app applies
            // to the routes it runs itself. This is the route a physical drive
            // takes on every Mac where the daemon is installed, which is most
            // of them, and without a deadline here a machine that never comes
            // up holds a spinner for as long as anybody is willing to watch it.
            //
            // Killing the script does not take the machine with it, so what
            // this attempt started is taken down too. Root here, which is the
            // one thing the app cannot do for itself.
            var ranOut = false
            let endBy = Date().addingTimeInterval(TransientFailure.deadline)
            while task.isRunning {
                if Date() >= endBy {
                    ranOut = true
                    task.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
            task.waitUntilExit()
            streamer.stop()
            if ranOut {
                EngineProcesses.stopWhatStartedSince(helpersBefore)
                Log.helper.error("the mount did not finish inside the deadline")
                let sofar = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                reply(
                    75,
                    Diagnostics.scrubbed(
                        sofar + "\n\(TransientFailure.deadlineReached) "
                            + "\(Int(TransientFailure.deadline)) seconds",
                        secret: credential))
                return
            }

            var output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            // Always leave a trace. A failure whose log is empty gives the user
            // nothing to report and us nothing to read; the exit status alone
            // says whether the script ran at all and how far it got.
            output +=
                "\nmount script exited with status \(task.terminationStatus)"
                + " for \(devicePath)"
            Log.helper.notice(
                "mount script exited \(task.terminationStatus, privacy: .public)")
            reply(task.terminationStatus, Diagnostics.scrubbed(output, secret: credential))
        } catch {
            Log.helper.error("the mount could not be run: \(error)")
            reply(71, "\(error)")
        }
    }

    func progress(reply: @escaping (String) -> Void) {
        let (text, secret, others) = progressQueue.sync { () -> (String, String?, [String]) in
            let (text, first) = transcriptForProgress()
            let rest = running.values.compactMap(\.credential).filter { $0 != first }
            return (text, first, rest)
        }
        // Every credential in flight, not just the one this transcript belongs
        // to: an engine that echoes a passphrase does not know whose it is.
        var scrubbed = Diagnostics.scrubbed(text, secret: secret)
        for other in others { scrubbed = Diagnostics.scrubbed(scrubbed, secret: other) }
        reply(scrubbed)
    }

    func identify(devicePath: String, reply: @escaping (String) -> Void) {
        // Waits for a device that has just been attached or handed back: a
        // moment's refusal to open is not an unrecognised filesystem.
        guard let sector = BootSector.readWaiting(devicePath: devicePath) else {
            Log.helper.notice("could not read the first sector")
            reply(VolumeFormat.unknown.rawValue)
            return
        }
        let format = BootSector.identify(sector)
        Log.helper.notice("partition identified as \(format.rawValue, privacy: .public)")
        reply(format.rawValue)
    }

    func removeYourself(reply: @escaping (Bool) -> Void) {
        // Nothing is removed while a drive is open: the mounts are served by
        // machines this daemon started, and taking it away underneath them
        // leaves them with nothing to eject them.
        guard
            !MountTableEntry.all(in: LukottaCore.mountTable()).contains(where: \.isEngineMount)
        else {
            Log.helper.notice("not removing myself: drives are open")
            return reply(false)
        }
        let job = HelperInfo.installedJobPath
        let tool = HelperInfo.installedToolPath
        Log.helper.notice("removing myself at the app's request")
        // Unloaded first, or launchd starts it again on the next connection.
        _ = LukottaCore.run("/bin/launchctl", ["bootout", "system/\(HelperInfo.machServiceName)"])
        let manager = FileManager.default
        let removed =
            ((try? manager.removeItem(atPath: job)) != nil)
            || !manager.fileExists(atPath: job)
        try? manager.removeItem(atPath: tool)
        reply(removed)
        // The reply has to leave before the process does.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    func unmount(mountPoint: String, reply: @escaping (Int32, String) -> Void) {
        let result = EngineStatus.unmount(mountPoint: mountPoint)
        Log.helper.notice("unmount succeeded: \(result.ok, privacy: .public)")
        reply(result.ok ? 0 : 1, result.message)
    }

    /// Add link-local loopback addresses until there are enough for `count`
    /// drives to be open at once.
    ///
    /// The engine picks a free loopback address for each drive it serves and
    /// creates one when none is free -- which it cannot do as the user, so
    /// without this the third drive is the last. The addresses are link-local
    /// (fe80::), which is what the engine itself creates when it runs as root,
    /// and they reach nothing outside this Mac.
    func makeRoom(forDrives count: Int, reply: @escaping (Int) -> Void) {
        // Zero means the opposite: take back the ones this app added, which is
        // what uninstalling asks for. Written as a count rather than a second
        // method so that no helper is ever too old to understand it.
        if count <= 0 {
            // Only when nothing at all is being served. The addresses are one
            // pool shared by every copy of this app on the Mac, and a released
            // app can be serving drives while a pre-release is uninstalled:
            // taking its address away would break a mount somebody is using.
            guard
                !MountTableEntry.all(in: LukottaCore.mountTable()).contains(where: \.isEngineMount)
            else {
                Log.helper.notice("not releasing addresses: drives are open")
                return reply(Capacity.addresses().count)
            }
            var released = 0
            // Every address this app can add, so releasing undoes adding
            // exactly. These two bounds were written apart and disagreed:
            // adding could reach .63, releasing stopped at .13, and the
            // remainder stayed on the interface after an uninstall.
            for last in 2...Capacity.lastLoopbackAddress {
                let address = "127.0.0.\(last)"
                guard Capacity.addresses().contains(address) else { continue }
                _ = LukottaCore.run("/sbin/ifconfig", ["lo0", "-alias", address])
                released += 1
            }
            Log.helper.notice("released \(released, privacy: .public) loopback addresses")
            return reply(Capacity.addresses().count)
        }
        let wanted = min(max(count, 1), Capacity.lastLoopbackAddress - 1)
        var have = Capacity.addresses().count
        // 127.0.0.2 upwards, which are loopback by definition and reach nothing
        // outside this Mac. Numbered from a fixed base so calling this again
        // lands on the same addresses rather than filling the interface with
        // new ones, and skipped where they are already there.
        var last = 1
        while have < wanted, last < Capacity.lastLoopbackAddress {
            last += 1
            let address = "127.0.0.\(last)"
            guard !Capacity.addresses().contains(address) else { continue }
            _ = LukottaCore.run(
                "/sbin/ifconfig", ["lo0", "alias", address, "netmask", "255.255.255.255"])
            have = Capacity.addresses().count
        }
        Log.helper.notice("loopback addresses: \(have, privacy: .public)")
        reply(have)
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }

    /// Exit, so that launchd starts the binary that is in the bundle now.
    ///
    /// Never while a mount is running: the drive somebody is opening is being
    /// served by this process, and going away in the middle of it would leave
    /// them with a failure and a machine nothing will take down. The app asks
    /// again after the mount it is waiting on has finished.
    func stepAside(reply: @escaping (Bool) -> Void) {
        let busy = progressQueue.sync { !running.isEmpty }
        if busy {
            Log.helper.notice("asked to step aside while serving a mount; staying")
            reply(false)
            return
        }
        Log.helper.notice("stepping aside so the newer daemon can start")
        reply(true)
        // After the reply has left the process, not before.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    /// The engine's own directory inside that user's Application Support.
    ///
    /// The same place the app uses, composed here from the invoking user's home
    /// because this runs as root and must never resolve anything against
    /// root's. It is handed to the engine in the mount script, so a mount made
    /// through the helper reads the same image as one made without it -- this
    /// app's own, and never the shared one another program may be using.
    private func engineHome(of home: String) -> String {
        // The same expression the app uses, against the invoking user's home
        // rather than root's. Both have to arrive at one path: otherwise a
        // mount made through the helper reads a different Linux environment
        // from one made without it, and the two are different versions the
        // moment either is updated.
        EngineEnvironment.engineHome(inHome: home, named: EngineEnvironment.appDirectoryName).path
    }

    /// The user this is being done for, whose home the engine resolves paths
    /// against.
    ///
    /// The connected app is the authority: it runs as that user. The console
    /// user is asked only if the connection somehow said root, and neither
    /// answer is replaced by a guess — 501 is the first account on a Mac and
    /// nothing more, so guessing it sent a second user's mount to somebody
    /// else's home directory.
    /// Whoever is logged in at the screen, or zero where nobody is.
    private func consoleUser() -> (uid: UInt32, gid: UInt32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        // The name is not wanted; the two numbers are written through the
        // pointers either way.
        SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
        return (UInt32(uid), UInt32(gid))
    }

    private func invokingUID() -> UInt32 {
        if let peerUID, peerUID != 0 { return UInt32(peerUID) }
        return consoleUser().uid
    }

    private func invokingGID() -> UInt32 {
        if let peerUID, peerUID != 0, let peerGID { return UInt32(peerGID) }
        return consoleUser().gid
    }

    /// Whether there is a user to do this for at all.
    ///
    /// Everything the helper composes is resolved against a home directory. If
    /// nothing says whose, the mount would be built against root's — or against
    /// whichever account happened to be first on this Mac — and would either
    /// fail or, worse, put a config in a stranger's home.
    private func hasAnInvokingUser() -> Bool {
        invokingUID() != 0
    }

    /// The console user's home, where the engine keeps its config.toml. The
    /// helper runs as root, so NSHomeDirectory would answer /var/root — a
    /// config there is one the engine, resolving against SUDO_UID, never reads.
    private func invokingHome() -> String? {
        guard let entry = getpwuid(invokingUID()), let dir = entry.pointee.pw_dir else {
            // No home means nowhere the engine would read a config from.
            // Answering /Users/Shared put one where nothing reads it, which
            // looks like the setting being ignored rather than a failure.
            return nil
        }
        return String(cString: dir)
    }
}

HelperService().run()
