//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//  This file contains code that ensures errno is captured correctly when doing syscalls and no ARC traffic can happen inbetween that *could* change the errno
//  value before we were able to read it.
//  Its important that all static methods are declared with `@inline(never)` so its not possible any ARC traffic happens while we need to read errno.
//
//  Created by Norman Maurer on 11/10/17.
//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@_exported import Darwin.C
#elseif os(Linux) || os(FreeBSD) || os(Android)
@_exported import Glibc
#else
let badOS = { fatalError("unsupported OS") }()
#endif

// Declare aliases to share more code and not need to repeat #if #else blocks
private let sysClose = close
private let sysShutdown = shutdown
private let sysBind = bind
private let sysFcntl: (Int32, Int32, Int32) -> Int32 = fcntl
private let sysSocket = socket
private let sysSetsockopt = setsockopt
private let sysGetsockopt = getsockopt
private let sysListen = listen
private let sysAccept = accept
private let sysConnect = connect
private let sysOpen: (UnsafePointer<CChar>, Int32) -> Int32 = open
private let sysOpenWithMode: (UnsafePointer<CChar>, Int32, mode_t) -> Int32 = open
private let sysWrite = write
private let sysWritev = writev
private let sysRead = read
private let sysLseek = lseek

private func isBlacklistedErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT:
        fallthrough
    case EBADF:
        return true
    default:
        return false
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapSyscallMayBlock<T: FixedWidthInteger>(where function: StaticString = #function, _ fn: () throws -> T) throws -> IOResult<T> {
    while true {
        let res = try fn()
        if res == -1 {
            let err = errno
            switch err {
            case EINTR:
                continue
            case EWOULDBLOCK:
                return .wouldBlock(0)
            default:
                assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
                throw IOError(errnoCode: err, function: function)
            }
           
        }
        return .processed(res)
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapSyscall<T: FixedWidthInteger>(where function: StaticString = #function, _ fn: () throws -> T) throws -> T {
    while true {
        let res = try fn()
        if res == -1 {
            let err = errno
            if err == EINTR {
                continue
            }
            assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
            throw IOError(errnoCode: err, function: function)
        }
        return res
    }
}

enum Shutdown {
    case RD
    case WR
    case RDWR
    
    fileprivate var cValue: CInt {
        switch self {
        case .RD:
            return CInt(SHUT_RD)
        case .WR:
            return CInt(SHUT_WR)
        case .RDWR:
            return CInt(SHUT_RDWR)
        }
    }
}

internal enum Posix {
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    static let SOCK_STREAM: CInt = CInt(Darwin.SOCK_STREAM)
    static let UIO_MAXIOV: Int = 1024
#elseif os(Linux) || os(FreeBSD) || os(Android)
    static let SOCK_STREAM: CInt = CInt(Glibc.SOCK_STREAM.rawValue)
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
#else
    static var SOCK_STREAM: CInt {
        fatalError("unsupported OS")
    }
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
#endif
    
    
    @inline(never)
    public static func shutdown(descriptor: Int32, how: Shutdown) throws {
        _ = try wrapSyscall {
            sysShutdown(descriptor, how.cValue)
        }
    }
    
    @inline(never)
    public static func close(descriptor: Int32) throws {
        _ = try wrapSyscall {
            sysClose(descriptor)
        }
    }
    
    @inline(never)
    public static func bind(descriptor: Int32, ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
         _ = try wrapSyscall {
            sysBind(descriptor, ptr, socklen_t(bytes))
        }
    }
    
    @inline(never)
    // TODO: Allow varargs
    public static func fcntl(descriptor: Int32, command: Int32, value: Int32) throws {
        _ = try wrapSyscall {
            sysFcntl(descriptor, command, value)
        }
    }
    
    @inline(never)
    public static func socket(domain: Int32, type: Int32, `protocol`: Int32) throws -> Int32 {
        return try wrapSyscall {
            let fd = Int32(sysSocket(domain, type, `protocol`))

            #if os(Linux)
                /* no SO_NOSIGPIPE on Linux :( */
                _ = unsafeBitCast(Glibc.signal(SIGPIPE, SIG_IGN) as sighandler_t?, to: Int.self)
            #else
                if fd != -1 {
                    _ = try? Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                }
            #endif
            return fd
        }
    }
    
    @inline(never)
    public static func setsockopt(socket: Int32, level: Int32, optionName: Int32,
                                  optionValue: UnsafeRawPointer, optionLen: socklen_t) throws {
        _ = try wrapSyscall {
            sysSetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }
    
    @inline(never)
    public static func getsockopt(socket: Int32, level: Int32, optionName: Int32,
                                  optionValue: UnsafeMutableRawPointer, optionLen: UnsafeMutablePointer<socklen_t>) throws {
         _ = try wrapSyscall {
            sysGetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }

    @inline(never)
    public static func listen(descriptor: Int32, backlog: Int32) throws {
        _ = try wrapSyscall {
            sysListen(descriptor, backlog)
        }
    }
    
    @inline(never)
    public static func accept(descriptor: Int32, addr: UnsafeMutablePointer<sockaddr>, len: UnsafeMutablePointer<socklen_t>) throws -> Int32? {
        let result: IOResult<Int> = try wrapSyscallMayBlock {
            let fd = sysAccept(descriptor, addr, len)

            #if !os(Linux)
                if (fd != -1) {
                    // TODO: Handle return code ?
                    _ = try? Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                }
            #endif
            return Int(fd)
        }
        
        switch result {
        case .processed(let fd):
            return Int32(fd)
        default:
            return nil
        }
    }
    
    @inline(never)
    public static func connect(descriptor: Int32, addr: UnsafePointer<sockaddr>, size: Int) throws -> Bool {
        do {
            _ = try wrapSyscall {
                sysConnect(descriptor, addr, socklen_t(size))
            }
            return true
        } catch let err as IOError {
            if err.errnoCode == EINPROGRESS {
                return false
            }
            throw err
        }
    }
    
    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: Int32, mode: mode_t) throws -> CInt {
        return try wrapSyscall {
            sysOpenWithMode(file, oFlag, mode)
        }
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: Int32) throws -> CInt {
        return try wrapSyscall {
            sysOpen(file, oFlag)
        }
    }
    
    @inline(never)
    public static func write(descriptor: Int32, pointer: UnsafePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            sysWrite(descriptor, pointer, size)
        }
    }
    
    @inline(never)
    public static func writev(descriptor: Int32, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            sysWritev(descriptor, iovecs.baseAddress!, Int32(iovecs.count))
        }
    }
    
    @inline(never)
    public static func read(descriptor: Int32, pointer: UnsafeMutablePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            Int(sysRead(descriptor, pointer, size))
        }
    }
    
    @discardableResult
    @inline(never)
    public static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try wrapSyscall {
            sysLseek(descriptor, offset, whence)
        }
    }

    // Its not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    public static func sendfile(descriptor: Int32, fd: Int32, offset: Int, count: Int) throws -> IOResult<Int> {
        var written: Int = 0
        do {
            _ = try wrapSyscall { () -> Int in
                #if os(macOS)
                    var w: off_t = off_t(count)
                    let result = Int(Darwin.sendfile(fd, descriptor, off_t(offset), &w, nil, 0))
                    written = Int(w)
                    return result
                #else
                    var off: off_t = offset
                    let result = Glibc.sendfile(descriptor, fd, &off, count)
                    if result >= 0 {
                        written = result
                    } else {
                        written = 0
                    }
                    return result
                #endif
            }
            return .processed(written)
        } catch let err as IOError {
            if err.errnoCode == EAGAIN {
                return .wouldBlock(written)
            }
            throw err
        }
    }

}

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
internal enum KQueue {

    // TODO: Figure out how to specify a typealias to the kevent struct without run into trouble with the swift compiler

    @inline(never)
    public static func kqueue() throws -> Int32 {
        return try wrapSyscall {
            Darwin.kqueue()
        }
    }
    
    @inline(never)
    public static func kevent0(kq: Int32, changelist: UnsafePointer<kevent>?, nchanges: Int32, eventlist: UnsafeMutablePointer<kevent>?, nevents: Int32, timeout: UnsafePointer<Darwin.timespec>?) throws -> Int32 {
        return try wrapSyscall {
            return kevent(kq, changelist, nchanges, eventlist, nevents, timeout)
        }
    }
}
#endif
