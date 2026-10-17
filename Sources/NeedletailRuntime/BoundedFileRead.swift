import Foundation
import NeedletailCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Bounded regular-file read shared by `config validate`, `doctor --probe`
/// and the test suites (S1): the path is opened with
/// `O_RDONLY | O_NOFOLLOW | O_NONBLOCK` and checked with `fstat` before any
/// byte is read, so FIFOs (no writer — `O_NONBLOCK` keeps the open from
/// hanging), sockets, devices, directories and symlinks are refused with an
/// actionable error instead of hanging or following links. Reads stop at
/// `limit + 1` bytes and fail closed with `fileTooLarge`.
public func readBoundedFile(_ path: String, limit: Int = ConfigLimits.maxFileBytes) throws -> Data {
    let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
    guard fd >= 0 else {
        throw ConfigError(
            path: "$", kind: .configNotFound,
            message: "file '\(path)' cannot be opened.",
            hint: "pass an existing readable regular file (symlinks are never followed).")
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0 else {
        throw ConfigError(
            path: "$", kind: .unsupportedFormat,
            message: "file '\(path)' cannot be statted.",
            hint: "pass a readable regular file.")
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
        throw ConfigError(
            path: "$", kind: .unsupportedFormat,
            message: "'\(path)' is not a regular file (no FIFO, socket, device, directory or symlink).",
            hint: "point --config at a versioned JSON regular file.")
    }
    var bytes = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let readCount = chunk.withUnsafeMutableBytes { pointer in
            read(fd, pointer.baseAddress, pointer.count)
        }
        guard readCount >= 0 else {
            throw ConfigError(
                path: "$", kind: .malformedJSON,
                message: "file '\(path)' cannot be read.",
                hint: "check the file is a readable regular file.")
        }
        if readCount == 0 { break }
        guard bytes.count + readCount <= limit + 1 else {
            throw ConfigError(
                path: "$", kind: .fileTooLarge,
                message: "file exceeds \(limit) bytes.",
                hint: "shrink the file; inputs are rejected before decoding.")
        }
        bytes.append(contentsOf: chunk.prefix(readCount))
    }
    guard bytes.count <= limit else {
        throw ConfigError(
            path: "$", kind: .fileTooLarge,
            message: "file exceeds \(limit) bytes.",
            hint: "shrink the file; inputs are rejected before decoding.")
    }
    return bytes
}
