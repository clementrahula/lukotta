// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// An NTFS volume as Finder sees it: AFP from netatalk in the guest, over an NFS mount Finder is not shown.
public enum AfpShare {
    static let guestLogin = ";AUTH=No%20User%20Authent@"

    public static func isHidden(_ entry: MountTableEntry) -> Bool {
        entry.isEngineMount && entry.options.contains("nobrowse")
    }

    public static func hostAndShare(ofNFSSource source: String) -> (host: String, share: String)? {
        guard let colon = source.firstIndex(of: ":") else { return nil }
        let host = String(source[..<colon])
        let share = (String(source[source.index(after: colon)...]) as NSString).lastPathComponent
        guard !host.isEmpty, !share.isEmpty, share != "/" else { return nil }
        return (host, share)
    }

    /// The engine host an AFP volume of ours is served from; nil for anything else.
    public static func afpHost(of source: String) -> String? {
        guard let at = source.range(of: "@", options: .backwards) else { return nil }
        let rest = source[at.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash])
        return host.hasPrefix("disk") && host.hasSuffix(".local") ? host : nil
    }

    /// The share's name as netatalk offers it: its config reader lowercases A to Z and nothing else.
    public static func servedName(_ share: String) -> String {
        String(
            String.UnicodeScalarView(
                share.unicodeScalars.map {
                    ("A"..."Z").contains($0) ? Unicode.Scalar($0.value + 32)! : $0
                }))
    }

    public static func url(host: String, share: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/;?#")
        let encoded = share.addingPercentEncoding(withAllowedCharacters: allowed) ?? share
        return "afp://\(guestLogin)\(host)/\(encoded)"
    }

    public static func afpPoints(forHost host: String, in table: String) -> [String] {
        MountTableEntry.all(in: table)
            .filter { $0.isAFP && afpHost(of: $0.source) == host }
            .map(\.mountPoint)
    }

    /// Mount a device's AFP share as the user, for Finder; on failure its hidden NFS goes too.
    public static func mountForFinder(device: String, uid: UInt32, gid: UInt32) -> Bool {
        let node = (device as NSString).lastPathComponent + "."
        let table = mountTable()
        guard
            let nfs = MountTableEntry.all(in: table)
                .first(where: { isHidden($0) && $0.source.hasPrefix(node) }),
            let pair = hostAndShare(ofNFSSource: nfs.source)
        else { return false }
        if !afpPoints(forHost: pair.host, in: table).isEmpty { return true }
        let point = freePoint(named: pair.share, in: table)
        mkdir(point, 0o755)
        chown(point, uid, gid)
        let address = url(host: pair.host, share: servedName(pair.share))
        let mount = ["-n", "-u", "#\(uid)", "/sbin/mount_afp", address, point]
        for _ in 0..<30 {
            _ = run("/usr/bin/sudo", mount, timeout: 30)
            if !afpPoints(forHost: pair.host, in: mountTable()).isEmpty { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        rmdir(point)
        _ = run("/sbin/umount", [nfs.mountPoint], timeout: 30)
        return false
    }

    static func freePoint(named share: String, in table: String) -> String {
        let taken = Set(MountTableEntry.all(in: table).map(\.mountPoint))
        var candidate = "/Volumes/" + share
        var n = 1
        while taken.contains(candidate) || !emptyOrAbsent(candidate) {
            candidate = "/Volumes/\(share) \(n)"
            n += 1
        }
        return candidate
    }

    static func emptyOrAbsent(_ path: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return !FileManager.default.fileExists(atPath: path)
        }
        return items.isEmpty
    }

    /// The hosts this app's own engine is serving: another copy of the app's mounts are not ours.
    public static func ownHosts(engine: String?, processes: String) -> Set<String> {
        guard let engine else { return [] }
        var hosts = Set<String>()
        let lines = processes.split(separator: "\n")
        for line in lines where line.hasPrefix(engine) && line.contains(" mount ") {
            if let dev = line.split(separator: " ").last(where: { $0.hasPrefix("/dev/disk") }) {
                hosts.insert((String(dev) as NSString).lastPathComponent + ".local")
            }
        }
        return hosts
    }

    /// Our hidden NFS mounts alone on this sweep and the last, and AFP volumes whose engine went.
    public static func orphans(in table: String, lonelyBefore: Set<String>, ours: Set<String>) -> (
        points: [String], lonely: Set<String>
    ) {
        let entries = MountTableEntry.all(in: table)
        let nfs = entries.filter {
            isHidden($0) && ours.contains(hostAndShare(ofNFSSource: $0.source)?.host ?? "")
        }
        let every = entries.filter(isHidden)
        let afp = entries.filter(\.isAFP)
        let afpHosts = Set(afp.compactMap { afpHost(of: $0.source) })
        let nfsHosts = Set(every.compactMap { hostAndShare(ofNFSSource: $0.source)?.host })
        let lonely = Set(
            nfs.filter {
                guard let host = hostAndShare(ofNFSSource: $0.source)?.host else { return false }
                return !afpHosts.contains(host)
            }.map(\.mountPoint))
        let lonelyAFP = afp.filter {
            afpHost(of: $0.source).map { !nfsHosts.contains($0) } ?? false
        }
        let gone = Array(lonely.intersection(lonelyBefore)).sorted()
        return (gone + lonelyAFP.map(\.mountPoint), lonely)
    }

    final class State: @unchecked Sendable {
        let lock = NSLock()
        var lonely: Set<String> = []
    }
    static let state = State()

    /// Nothing is taken while a drive is being opened: its NFS mount is alone until its AFP volume comes.
    public static func takeDownOrphans(mounting: Bool, engine: String?) {
        state.lock.lock()
        let table = mountTable()
        let processes = run("/bin/ps", ["-axww", "-o", "command="])?.out ?? ""
        let ours = ownHosts(engine: engine, processes: processes)
        var found = orphans(in: table, lonelyBefore: mounting ? [] : state.lonely, ours: ours)
        if mounting { found.lonely = [] }
        state.lonely = found.lonely
        state.lock.unlock()
        let hidden = Set(MountTableEntry.all(in: table).filter(isHidden).map(\.mountPoint))
        for point in found.points {
            if hidden.contains(point) {
                Log.mount.notice("Finder's volume was ejected; letting its engine go")
                if run("/sbin/umount", [point], timeout: 30)?.ok != true {
                    _ = run("/sbin/umount", ["-f", point], timeout: 20)
                }
            } else {
                Log.mount.notice("the engine behind an AFP volume went; taking the volume away")
                _ = run("/sbin/umount", ["-f", point], timeout: 20)
            }
            rmdir(point)
        }
    }

    /// Before an engine's NFS mount is taken down, the AFP volume Finder shows for it.
    public static func unmountPartner(ofNFS mountPoint: String) {
        let table = mountTable()
        guard
            let nfs = MountTableEntry.all(in: table)
                .first(where: { $0.isEngineMount && $0.mountPoint == mountPoint }),
            let pair = hostAndShare(ofNFSSource: nfs.source)
        else { return }
        for point in afpPoints(forHost: pair.host, in: table) {
            if run("/sbin/umount", [point], timeout: 30)?.ok != true {
                _ = run("/sbin/umount", ["-f", point], timeout: 20)
            }
            rmdir(point)
        }
    }
}
