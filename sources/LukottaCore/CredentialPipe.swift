// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// Hands a credential to the mount script through its pipe.
public enum CredentialPipe {
    /// On a thread of its own that ends with the script: one that never reads leaves nothing blocked behind.
    @discardableResult
    public static func handOver(
        _ credential: String, to fifo: URL, whileRunning pid: pid_t,
        giveUpAfter limit: TimeInterval = TransientFailure.deadline + 60
    ) -> Thread {
        let bytes = Array(credential.utf8)
        let path = fifo.path
        let thread = Thread {
            let endBy = Date().addingTimeInterval(limit)
            while kill(pid, 0) == 0, Date() < endBy {
                let fd = Darwin.open(path, O_WRONLY | O_NONBLOCK)
                guard fd >= 0 else {
                    guard errno == ENXIO || errno == EINTR else { return }
                    usleep(50_000)
                    continue
                }
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                var sent = 0
                while sent < bytes.count {
                    let n = bytes[sent...].withUnsafeBytes {
                        Darwin.write(fd, $0.baseAddress, $0.count)
                    }
                    if n <= 0 { break }
                    sent += n
                }
                Darwin.close(fd)
                return
            }
        }
        thread.start()
        return thread
    }
}
