import Foundation
import NetworkExtension
import Darwin

/// All operations run on the provider queue. The engine retains ownership of fd.
final class PacketPump {
    private let flow: NEPacketTunnelFlow
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var running = false
    var blocksIPv6 = false
    var mtu: Int
    private(set) var sent: UInt64 = 0
    private(set) var received: UInt64 = 0
    private(set) var dropped: UInt64 = 0
    init(flow: NEPacketTunnelFlow, fd: Int32, mtu: Int, queue: DispatchQueue) {
        self.flow = flow; self.fd = fd; self.mtu = mtu; self.queue = queue
    }
    func start() {
        guard !running else { return }
        running = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        self.source = source
        source.resume()
        readPackets()
    }
    func stop() { running = false; source?.cancel(); source = nil }
    private func readPackets() {
        guard running else { return }
        flow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                for (packet, proto) in zip(packets, protocols) {
                    guard PacketCodec.canForward(family: proto.int32Value, blocksIPv6: self.blocksIPv6),
                          let frame = PacketCodec.encode(packet, family: proto.int32Value, mtu: self.mtu) else {
                        self.dropped += 1; continue
                    }
                    let count = frame.withUnsafeBytes { Darwin.send(self.fd, $0.baseAddress, $0.count, 0) }
                    // Datagram queue is bounded by the kernel; drop on backpressure instead of allocating an unbounded queue.
                    if count == frame.count { self.sent += 1 } else { self.dropped += 1 }
                }
                self.readPackets()
            }
        }
    }
    private func drain() {
        guard running else { return }
        var buffer = [UInt8](repeating: 0, count: 9005)
        // Yield after a bounded batch so cancellation and path events cannot starve.
        for _ in 0..<64 {
            let length = recv(fd, &buffer, buffer.count, 0)
            if length < 0 { if errno != EAGAIN && errno != EWOULDBLOCK { dropped += 1 }; break }
            if length == 0 { break }
            guard let (packet, family) = PacketCodec.decode(Data(buffer.prefix(length)), mtu: mtu),
                  PacketCodec.canForward(family: family, blocksIPv6: blocksIPv6) else { dropped += 1; continue }
            if flow.writePackets([packet], withProtocols: [NSNumber(value: family)]) { received += 1 }
            else { dropped += 1 }
        }
    }
}
