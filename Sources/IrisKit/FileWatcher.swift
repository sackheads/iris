import Foundation
import CoreServices

final class ContinuationWrapper {
    let continuation: AsyncStream<[String]>.Continuation
    init(_ continuation: AsyncStream<[String]>.Continuation) {
        self.continuation = continuation
    }
}

final class FileWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    
    deinit {
        stop()
    }
    
    func watch(paths: [String]) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let wrapper = ContinuationWrapper(continuation)
            
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(wrapper).toOpaque(),
                retain: { info in
                    guard let info = info else { return nil }
                    _ = Unmanaged<ContinuationWrapper>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info = info else { return }
                    Unmanaged<ContinuationWrapper>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            
            let callback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                guard let info = clientCallBackInfo else { return }
                let wrapper = Unmanaged<ContinuationWrapper>.fromOpaque(info).takeUnretainedValue()
                
                // The stream is created with kFSEventStreamCreateFlagUseCFTypes, so eventPaths
                // is a CFArray of CFStrings. Bridge it safely rather than reinterpreting raw bits.
                guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else { return }
                wrapper.continuation.yield(paths)
            }
            
            let nsPaths = paths.map { ($0 as NSString).expandingTildeInPath } as CFArray
            
            self.stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                nsPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                1.0, // latency in seconds
                UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
            )
            
            if let stream = self.stream {
                FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
                if !FSEventStreamStart(stream) {
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    self.stream = nil
                    continuation.finish()
                }
            } else {
                continuation.finish()
            }
            
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }
    
    func stop() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
