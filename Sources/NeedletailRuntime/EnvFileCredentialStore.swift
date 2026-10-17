import Foundation
import NeedletailCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// M1-A Linux credential resolution (SPEC §5.3): environment variables and
/// owner-only (`0600`) credential files. Exactly one reference is resolved
/// per call for the named operation; the value is returned to the caller
/// and never logged, exported, or placed in a child environment by this
/// type. Files are opened with `O_NOFOLLOW` and checked with `fstat`
/// (regular file, zero group/other permission bits) before any byte is
/// read; reads are bounded. A permissive ACL beyond the mode bits is a
/// documented limitation, not a detected condition.
public struct EnvFileCredentialStore: CredentialStore, Sendable {
    public init() {}

    public func resolve(_ reference: CredentialReference, for operation: String) throws -> String {
        switch reference.kind {
        case .env(let name):
            guard !name.isEmpty else {
                throw CredentialError.missingEnv(name: name)
            }
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                throw CredentialError.missingEnv(name: name)
            }
            return value
        case .file(let path):
            return try readCredentialFile(path)
        case .keychain(let account):
            throw CredentialError.unsupportedOnLinux(what: "keychain:\(account) for '\(operation)'")
        }
    }

    private func readCredentialFile(_ path: String) throws -> String {
        // O_NONBLOCK (S1): opening a FIFO without a writer must not hang;
        // the S_ISREG check below then refuses it. Regular files are
        // unaffected by O_NONBLOCK.
        let fd = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else {
            throw CredentialError.unreadableFile(path: path, reason: "open failed")
        }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw CredentialError.unreadableFile(path: path, reason: "fstat failed")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw CredentialError.unreadableFile(path: path, reason: "not a regular file (no symlinks, directories or devices)")
        }
        let permissions = status.st_mode & 0o777
        guard permissions & 0o077 == 0 else {
            throw CredentialError.insecurePermissions(
                path: path,
                actual: String(format: "0o%03o", permissions))
        }
        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = chunk.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress, pointer.count)
            }
            guard readCount >= 0 else {
                throw CredentialError.unreadableFile(path: path, reason: "read failed")
            }
            if readCount == 0 { break }
            guard bytes.count + readCount <= ConfigLimits.maxCredentialBytes + 1 else {
                throw CredentialError.credentialTooLarge(path: path)
            }
            bytes.append(contentsOf: chunk.prefix(readCount))
        }
        guard bytes.count <= ConfigLimits.maxCredentialBytes else {
            throw CredentialError.credentialTooLarge(path: path)
        }
        guard var text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
            throw CredentialError.unreadableFile(path: path, reason: "empty or non-UTF-8 content")
        }
        if text.hasSuffix("\n") {
            text = String(text.dropLast())
            if text.hasSuffix("\r") {
                text = String(text.dropLast())
            }
        }
        guard !text.isEmpty else {
            throw CredentialError.unreadableFile(path: path, reason: "empty content")
        }
        return text
    }
}
