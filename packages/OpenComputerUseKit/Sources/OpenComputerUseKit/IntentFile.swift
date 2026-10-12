import Foundation
import Darwin

/// Reading metadata or result files must not block on a FIFO or device.
enum IntentFile {
    static func readPrefix(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw ComputerUseError.stateUnavailable("Cannot read Intent file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ComputerUseError.stateUnavailable("Intent file must be a regular file")
        }
        return try handle.read(upToCount: maximum) ?? Data()
    }
}
