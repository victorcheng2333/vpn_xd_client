import Foundation
import NetworkExtension
import Darwin

protocol PacketFlowIO: AnyObject {
    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void)
    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool
}

extension NEPacketTunnelFlow: PacketFlowIO {}

/// One pump per engine session; all operations run on the provider queue.
/// The engine retains ownership of fd, including after dispatch-source cancellation.
final class PacketPump: @unchecked Sendable {
    static let maximumQueuedPackets = 512
    static let maximumQueuedBytes = 2 * 1024 * 1024
    private let flow: PacketFlowIO
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var retry: DispatchWorkItem?
    private var retryDelayMilliseconds = 1
    private var started = false
    private var running = false
    private var readPending = false
    private var pending: [Data] = []
    private var pendingIndex = 0
    private var statistics = PacketPumpStatistics()
    var blocksIPv6 = false
    var mtu: Int
    private(set) var sent: UInt64 = 0
    private(set) var received: UInt64 = 0
    var dropped: UInt64 { statistics.droppedPackets }
    var diagnostics: PacketPumpStatistics {
        var value = statistics
        value.mtu = mtu
        value.queuedPackets = pending.count - pendingIndex
        return value
    }
    init(flow: PacketFlowIO, fd: Int32, mtu: Int, queue: DispatchQueue) {
        self.flow = flow; self.fd = fd; self.mtu = mtu; self.queue = queue
        func bufferSize(_ option: Int32) -> Int {
            var value: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: value))
            return getsockopt(fd, SOL_SOCKET, option, &value, &size) == 0 ? Int(value) : 0
        }
        statistics.sendBufferBytes = bufferSize(SO_SNDBUF)
        statistics.receiveBufferBytes = bufferSize(SO_RCVBUF)
    }
    func start() {
        guard !started else { return }
        started = true
        running = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        self.source = source
        source.resume()
        readPackets()
    }
    func stop() {
        running = false
        source?.cancel(); source = nil
        retry?.cancel(); retry = nil
        pending.removeAll(); pendingIndex = 0
    }
    private func readPackets() {
        guard running, !readPending, pending.isEmpty else { return }
        readPending = true
        flow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                self.readPending = false
                var queuedBytes = 0
                self.statistics.invalidPacketDrops += UInt64(abs(packets.count - protocols.count))
                for (packet, proto) in zip(packets, protocols) {
                    if proto.int32Value == AF_INET6 && self.blocksIPv6 {
                        self.statistics.policyDrops += 1; continue
                    }
                    guard let frame = PacketCodec.encode(packet, family: proto.int32Value, mtu: self.mtu) else {
                        self.statistics.invalidPacketDrops += 1; continue
                    }
                    // Retain only this batch, with explicit memory limits. Do not
                    // ask packetFlow for more data while the engine is behind.
                    guard self.pending.count < Self.maximumQueuedPackets,
                          queuedBytes + frame.count <= Self.maximumQueuedBytes else {
                        self.statistics.overflowDrops += 1; continue
                    }
                    self.pending.append(frame)
                    queuedBytes += frame.count
                }
                self.statistics.peakQueuedPackets = max(self.statistics.peakQueuedPackets, self.pending.count)
                self.flushUpload()
            }
        }
    }
    private func flushUpload() {
        guard running else { return }
        // A bounded turn also lets download ACKs, cancellation and path events run.
        for _ in 0..<64 {
            guard pendingIndex < pending.count else { break }
            let frame = pending[pendingIndex]
            // Settings can change while a batch waits for the engine.
            if frame.count > mtu + 4 {
                statistics.invalidPacketDrops += 1; pendingIndex += 1; continue
            }
            if blocksIPv6 && frame[3] == UInt8(AF_INET6) {
                statistics.policyDrops += 1; pendingIndex += 1; continue
            }
            let count = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            let error = errno
            if count == frame.count {
                sent += 1; statistics.bytesToTunnel += UInt64(frame.count - 4)
                pendingIndex += 1
                retryDelayMilliseconds = 1
            } else if count < 0 && (error == EAGAIN || error == EWOULDBLOCK || error == ENOBUFS) {
                statistics.uploadBackpressureEvents += 1
                scheduleUploadRetry()
                return
            } else if count < 0 && error == EINTR {
                continue // Retry the same datagram without losing ordering.
            } else {
                statistics.socketErrorDrops += 1; pendingIndex += 1
            }
        }
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true); pendingIndex = 0
            readPackets()
        } else {
            queue.async { [weak self] in self?.flushUpload() }
        }
    }
    private func scheduleUploadRetry() {
        guard retry == nil else { return }
        // Darwin AF_UNIX datagrams can return ENOBUFS while kqueue/select still
        // reports writable. A write source would spin. Retry only while blocked,
        // backing off to 16 ms if the engine is paused; reset on forward progress.
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.retry = nil
            self.flushUpload()
        }
        retry = job
        queue.asyncAfter(deadline: .now() + .milliseconds(retryDelayMilliseconds), execute: job)
        retryDelayMilliseconds = min(16, retryDelayMilliseconds * 2)
    }
    private func drain() {
        guard running else { return }
        var buffer = [UInt8](repeating: 0, count: 9005)
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        // Yield after a bounded batch so cancellation and path events cannot starve.
        for _ in 0..<64 {
            let length = recv(fd, &buffer, buffer.count, 0)
            if length < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { statistics.socketErrorDrops += 1 }
                break
            }
            if length == 0 { break }
            guard let (packet, family) = PacketCodec.decode(Data(buffer.prefix(length)), mtu: mtu) else {
                statistics.invalidPacketDrops += 1; continue
            }
            if family == AF_INET6 && blocksIPv6 { statistics.policyDrops += 1; continue }
            packets.append(packet); protocols.append(NSNumber(value: family))
        }
        if !packets.isEmpty {
            if flow.writePackets(packets, withProtocols: protocols) {
                received += UInt64(packets.count)
                statistics.bytesFromTunnel += packets.reduce(0) { $0 + UInt64($1.count) }
            } else { statistics.deliveryDrops += UInt64(packets.count) }
        }
    }
}
