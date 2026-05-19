import Foundation

final class CoreRunLoopThread: @unchecked Sendable {
    static let shared = CoreRunLoopThread()

    private final class RunLoopBox: @unchecked Sendable {
        var runLoop: CFRunLoop?
    }

    private let runLoop: CFRunLoop

    private init() {
        let ready = DispatchSemaphore(value: 0)
        let box = RunLoopBox()
        let thread = Thread {
            let timer = Timer(timeInterval: 3600, repeats: true) { _ in }
            RunLoop.current.add(timer, forMode: .common)
            box.runLoop = CFRunLoopGetCurrent()
            ready.signal()
            RunLoop.current.run()
        }
        thread.name = "com.kwwk.computer-use-core.run-loop"
        thread.start()
        ready.wait()
        runLoop = box.runLoop!
    }

    func addSource(_ source: CFRunLoopSource, mode: CFRunLoopMode = .commonModes) {
        CFRunLoopAddSource(runLoop, source, mode)
        CFRunLoopWakeUp(runLoop)
    }
}
