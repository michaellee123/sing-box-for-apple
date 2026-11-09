#if os(macOS) || JAILBREAK
    import Foundation
    import Libbox

    public enum ConnectionOwnerLookup {
        public struct Result {
            public let userId: Int32
            public let userName: String
            public let processPaths: [String]
        }

        public static func find(
            ipProtocol: Int32,
            sourceAddress: String,
            sourcePort: Int32,
            destinationAddress: String,
            destinationPort: Int32
        ) -> Result? {
            var error: NSError?
            if let result = LibboxFindConnectionOwner(
                ipProtocol,
                sourceAddress,
                sourcePort,
                destinationAddress,
                destinationPort,
                &error
            ) {
                return Result(
                    userId: result.userId,
                    userName: result.userName,
                    processPaths: result.processPaths()?.toArray() ?? []
                )
            }
            #if os(macOS)
                return DarwinProcessLookup.shared.find(
                    ipProtocol: ipProtocol,
                    sourceAddress: sourceAddress,
                    sourcePort: sourcePort,
                    destinationAddress: destinationAddress,
                    destinationPort: destinationPort
                )
            #else
                return nil
            #endif
        }
    }

    #if os(macOS)
        private final class DarwinProcessLookup {
        static let shared = DarwinProcessLookup()

        private struct Entry {
            let localAddress: Data
            let remoteAddress: Data
            let localPort: UInt16
            let remotePort: UInt16
            let userId: Int32
            let pid: Int32
        }

        private struct Snapshot {
            let createdAt: Date
            let entries: [Entry]
        }

        private let lock = NSLock()
        private var snapshots: [Int32: Snapshot] = [:]

        func find(
            ipProtocol: Int32,
            sourceAddress: String,
            sourcePort: Int32,
            destinationAddress: String,
            destinationPort: Int32
        ) -> ConnectionOwnerLookup.Result? {
            guard ipProtocol == IPPROTO_TCP || ipProtocol == IPPROTO_UDP,
                  let source = parseAddress(sourceAddress),
                  let destination = parseAddress(destinationAddress)
            else {
                return nil
            }
            lock.lock()
            defer { lock.unlock() }
            var snapshot = snapshots[ipProtocol]
            let fromCache = snapshot.map { Date().timeIntervalSince($0.createdAt) <= 0.2 } ?? false
            if !fromCache {
                snapshot = Snapshot(createdAt: Date(), entries: buildEntries(ipProtocol: ipProtocol))
                snapshots[ipProtocol] = snapshot
            }
            if let matched = match(
                snapshot?.entries ?? [],
                ipProtocol: ipProtocol,
                source: source,
                sourcePort: UInt16(truncatingIfNeeded: sourcePort),
                destination: destination,
                destinationPort: UInt16(truncatingIfNeeded: destinationPort)
            ), matched.exact || !fromCache, let result = result(for: matched.entry) {
                return result
            }
            guard fromCache else { return nil }
            let fresh = Snapshot(createdAt: Date(), entries: buildEntries(ipProtocol: ipProtocol))
            snapshots[ipProtocol] = fresh
            guard let matched = match(
                fresh.entries,
                ipProtocol: ipProtocol,
                source: source,
                sourcePort: UInt16(truncatingIfNeeded: sourcePort),
                destination: destination,
                destinationPort: UInt16(truncatingIfNeeded: destinationPort)
            ), let result = result(for: matched.entry) else {
                return nil
            }
            return result
        }

        private func result(for entry: Entry) -> ConnectionOwnerLookup.Result? {
            guard let path = processPath(pid: entry.pid) else { return nil }
            return ConnectionOwnerLookup.Result(
                userId: entry.userId,
                userName: userName(uid: entry.userId),
                processPaths: [path]
            )
        }

        private func buildEntries(ipProtocol: Int32) -> [Entry] {
            let capacity = proc_listallpids(nil, 0)
            guard capacity > 0 else { return [] }
            var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
            let pidBytes = pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            }
            guard pidBytes > 0 else { return [] }
            var entries: [Entry] = []
            for pid in pids.prefix(Int(pidBytes) / MemoryLayout<pid_t>.size) where pid > 0 {
                let fdBufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
                guard fdBufferSize > 0 else { continue }
                var fileDescriptors = [proc_fdinfo](
                    repeating: proc_fdinfo(),
                    count: Int(fdBufferSize) / MemoryLayout<proc_fdinfo>.size
                )
                let fdBytes = fileDescriptors.withUnsafeMutableBytes {
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                }
                guard fdBytes > 0 else { continue }
                var userId: Int32 = -1
                var bsdInfo = proc_bsdinfo()
                if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                    userId = Int32(bitPattern: bsdInfo.pbi_uid)
                }
                for descriptor in fileDescriptors.prefix(Int(fdBytes) / MemoryLayout<proc_fdinfo>.size)
                    where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET
                {
                    var socketInfo = socket_fdinfo()
                    guard proc_pidfdinfo(
                        pid,
                        descriptor.proc_fd,
                        PROC_PIDFDSOCKETINFO,
                        &socketInfo,
                        Int32(MemoryLayout<socket_fdinfo>.size)
                    ) == MemoryLayout<socket_fdinfo>.size else { continue }
                    guard socketInfo.psi.soi_protocol == ipProtocol else { continue }
                    let info = ipProtocol == IPPROTO_TCP
                        ? socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini
                        : socketInfo.psi.soi_proto.pri_in
                    var localAddress: Data?
                    var remoteAddress: Data?
                    if info.insi_vflag & UInt8(INI_IPV4) != 0 {
                        localAddress = withUnsafeBytes(of: info.insi_laddr.ina_46.i46a_addr4) { Data($0) }
                        remoteAddress = withUnsafeBytes(of: info.insi_faddr.ina_46.i46a_addr4) { Data($0) }
                    } else if info.insi_vflag & UInt8(INI_IPV6) != 0 {
                        localAddress = withUnsafeBytes(of: info.insi_laddr.ina_6) { Data($0) }
                        remoteAddress = withUnsafeBytes(of: info.insi_faddr.ina_6) { Data($0) }
                    }
                    guard let localAddress, let remoteAddress else { continue }
                    entries.append(Entry(
                        localAddress: localAddress,
                        remoteAddress: remoteAddress,
                        localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: info.insi_lport)),
                        remotePort: UInt16(bigEndian: UInt16(truncatingIfNeeded: info.insi_fport)),
                        userId: userId,
                        pid: pid
                    ))
                }
            }
            return entries
        }

        private func match(
            _ entries: [Entry],
            ipProtocol: Int32,
            source: Data,
            sourcePort: UInt16,
            destination: Data,
            destinationPort: UInt16
        ) -> (entry: Entry, exact: Bool)? {
            var localFallback: Entry?
            var wildcardFallback: Entry?
            for entry in entries where entry.localPort == sourcePort {
                if entry.localAddress == source,
                   entry.remotePort == destinationPort,
                   entry.remoteAddress == destination
                {
                    return (entry, true)
                }
                guard ipProtocol == IPPROTO_UDP else { continue }
                if localFallback == nil, entry.localAddress == source {
                    localFallback = entry
                }
                if wildcardFallback == nil, entry.localAddress.allSatisfy({ $0 == 0 }) {
                    wildcardFallback = entry
                }
            }
            return (localFallback ?? wildcardFallback).map { ($0, false) }
        }

        private func parseAddress(_ address: String) -> Data? {
            var ipv4 = in_addr()
            if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
                return withUnsafeBytes(of: ipv4) { Data($0) }
            }
            var ipv6 = in6_addr()
            if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
                return withUnsafeBytes(of: ipv6) { Data($0) }
            }
            return nil
        }

        private func processPath(pid: Int32) -> String? {
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = buffer.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            guard length > 0 else { return nil }
            return String(cString: buffer)
        }

        private func userName(uid: Int32) -> String {
            guard uid >= 0, let entry = getpwuid(uid_t(uid)) else { return "" }
            return String(cString: entry.pointee.pw_name)
        }
    }
    #endif
#endif
