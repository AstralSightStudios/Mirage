import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

/// Signals and queries for a process by PID (QEMU outlives the Mirage that
/// started it, so it is often not our own `Process`).
public enum HostProcess {
    #if os(Windows)
    private static let synchronize: DWORD = 0x0010_0000
    private static let queryLimitedInformation: DWORD = 0x1000
    private static let terminateRight: DWORD = 0x0001

    private static func withHandle<R>(_ pid: Int32, _ access: DWORD, _ body: (HANDLE) -> R) -> R? {
        guard let h = OpenProcess(access, false, DWORD(bitPattern: pid)) else { return nil }
        defer { CloseHandle(h) }
        return body(h)
    }
    #endif

    public static func isAlive(_ pid: Int32) -> Bool {
        #if os(Windows)
        return withHandle(pid, synchronize) { WaitForSingleObject($0, 0) == DWORD(WAIT_TIMEOUT) } ?? false
        #else
        return kill(pid, 0) == 0
        #endif
    }

    /// Asks the process to quit (SIGTERM; on Windows there is no polite
    /// signal for a console-less process, so this ends it).
    public static func terminate(_ pid: Int32) {
        #if os(Windows)
        _ = withHandle(pid, terminateRight) { TerminateProcess($0, 1) }
        #else
        kill(pid, SIGTERM)
        #endif
    }

    public static func forceKill(_ pid: Int32) {
        #if os(Windows)
        _ = withHandle(pid, terminateRight) { TerminateProcess($0, 9) }
        #else
        kill(pid, SIGKILL)
        #endif
    }

    /// Full path of the process's executable.
    public static func executablePath(_ pid: Int32) -> String? {
        #if canImport(Darwin)
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
        #elseif os(Windows)
        return withHandle(pid, queryLimitedInformation) { h -> String? in
            var buf = [WCHAR](repeating: 0, count: 32768)
            var size = DWORD(buf.count)
            guard QueryFullProcessImageNameW(h, 0, &buf, &size) else { return nil }
            return String(decodingCString: buf, as: UTF16.self)
        } ?? nil
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        #endif
    }

    /// Calls `handler` on the main queue once the process exits.
    public static func watchExit(_ pid: Int32, handler: @escaping @MainActor () -> Void) -> ExitWatch {
        #if canImport(Darwin)
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler {
            MainActor.assumeIsolated { handler() }
        }
        src.resume()
        return ExitWatch(cancel: { src.cancel() })
        #else
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler {
            guard !isAlive(pid) else { return }
            timer.cancel()
            MainActor.assumeIsolated { handler() }
        }
        timer.resume()
        return ExitWatch(cancel: { timer.cancel() })
        #endif
    }

    public final class ExitWatch {
        private let onCancel: () -> Void
        init(cancel: @escaping () -> Void) { onCancel = cancel }
        public func cancel() { onCancel() }
    }
}
