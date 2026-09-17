import Foundation
import Darwin

private func check(_ condition: Bool, _ message: String) {
    if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private final class TestFlow: PacketFlowIO {
    var reply: (@Sendable ([Data], [NSNumber]) -> Void)?
    var reads = 0
    var writes: [[Data]] = []
    var acceptWrites = true
    func readPackets(completionHandler: @escaping @Sendable ([Data], [NSNumber]) -> Void) {
        check(reply == nil, "only one packetFlow read may be outstanding")
        reads += 1
        reply = completionHandler
    }
    func writePackets(_ packets: [Data], withProtocols protocols: [NSNumber]) -> Bool {
        check(packets.count == protocols.count, "downstream packet and protocol counts agree")
        writes.append(packets)
        return acceptWrites
    }
    func deliver(_ packets: [Data], family: Int32 = AF_INET) {
        check(reply != nil, "packetFlow must request a batch before delivery")
        let callback = reply
        reply = nil
        callback?(packets, packets.map { _ in NSNumber(value: family) })
    }
}

private func packet(_ sequence: Int, size: Int = 1400) -> Data {
    var data = Data(repeating: 0, count: size)
    data[0] = 0x45
    data[2] = UInt8(size >> 8); data[3] = UInt8(size & 255)
    data[4] = UInt8(sequence >> 8); data[5] = UInt8(sequence & 255)
    return data
}

private final class Fixture {
    let queue = DispatchQueue(label: "PacketPumpTests")
    let flow = TestFlow()
    let pump: PacketPump
    let peer: Int32
    private let pumpFD: Int32
    init(mtu: Int = 1400) {
        var pair: [Int32] = [-1, -1]
        check(socketpair(AF_UNIX, SOCK_DGRAM, 0, &pair) == 0, "create local datagram bridge")
        for fd in pair {
            check(fcntl(fd, F_SETFL, O_NONBLOCK) == 0, "make bridge nonblocking")
            var size: Int32 = 4096
            check(setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0, "constrain receive buffer")
        }
        peer = pair[0]; pumpFD = pair[1]
        pump = PacketPump(flow: flow, fd: pair[1], mtu: mtu, queue: queue)
        queue.sync { pump.start() }
    }
    func deliver(_ packets: [Data], family: Int32 = AF_INET) {
        queue.sync { flow.deliver(packets, family: family) }
        queue.sync {} // Process the asynchronous packetFlow completion.
    }
    func receive() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 9005)
        let count = recv(peer, &buffer, buffer.count, 0)
        if count < 0 {
            check(errno == EAGAIN || errno == EWOULDBLOCK, "expected nonblocking receive")
            return nil
        }
        return PacketCodec.decode(Data(buffer.prefix(count)), mtu: 1400)?.0
    }
    deinit {
        queue.sync { pump.stop() }
        // The production engine owns the fds; dispatch sources must not close them.
        close(peer); close(pumpFD)
    }
}

@main private enum PacketPumpTests {
    static func main() {
        let fixture = Fixture()
        let packets = (0..<64).map { packet($0) }
        fixture.deliver(packets)
        fixture.queue.sync {
            check(fixture.pump.sent < 64, "experiment actually fills the bridge")
            check(fixture.pump.dropped == 0, "a full upload bridge must retain packets, not drop them (dropped \(fixture.pump.dropped)/64)")
            check(fixture.flow.reads == 1, "pause packetFlow reads until the pending upload batch drains")
        }
        var received: [Data] = []
        let deadline = Date().addingTimeInterval(5)
        while received.count < packets.count && Date() < deadline {
            if let data = fixture.receive() { received.append(data) }
            usleep(1000) // Model an engine that consumes more slowly than packetFlow produces.
        }
        check(received == packets, "backpressured upload is delivered completely and in order")
        fixture.queue.sync {
            check(fixture.pump.sent == 64 && fixture.pump.dropped == 0, "upload counters reflect successful delivery")
            check(fixture.flow.reads == 2, "resume packetFlow after draining")
            check(fixture.pump.diagnostics.uploadBackpressureEvents > 0, "record transient upload backpressure separately from loss")
            check(fixture.pump.diagnostics.bytesToTunnel == 64 * 1400, "byte counts exclude Darwin address-family prefix")
        }
        testQueueLimits()
        testStop()
        testDownstreamBatch()
        testFilteringAndSettingsChange()
        print("Passed packet pump regressions: upload backpressure/FIFO, bounded queues, stop, downstream batches, filtering and MTU changes.")
    }

    private static func testQueueLimits() {
        do {
            let fixture = Fixture()
            fixture.deliver((0..<600).map { packet($0) })
            fixture.queue.sync {
                let metrics = fixture.pump.diagnostics
                check(metrics.overflowDrops == 88, "oversized packetFlow batch has an explicit packet bound")
                check(metrics.queuedPackets + Int(fixture.pump.sent) == 512, "bounded batch retains all accepted packets")
                check(fixture.flow.reads == 1, "queue cap never creates an unbounded stream of reads")
            }
        }
        do {
            let fixture = Fixture(mtu: 9000)
            fixture.deliver((0..<300).map { packet($0, size: 9000) })
            fixture.queue.sync {
                let metrics = fixture.pump.diagnostics
                check(metrics.peakQueuedPackets == (2 * 1024 * 1024) / 9004, "queue also respects a byte bound with jumbo packets")
                check(metrics.overflowDrops == UInt64(300 - metrics.peakQueuedPackets), "byte-limit drops are counted explicitly")
            }
        }
    }

    private static func testStop() {
        do {
            let fixture = Fixture()
            fixture.deliver((0..<64).map { packet($0) })
            let sentBeforeStop = fixture.queue.sync { () -> UInt64 in
                fixture.pump.stop(); fixture.pump.stop()
                return fixture.pump.sent
            }
            while fixture.receive() != nil {}
            usleep(40000)
            fixture.queue.sync {
                check(fixture.pump.sent == sentBeforeStop, "a scheduled retry cannot send after stop")
                check(fixture.pump.diagnostics.queuedPackets == 0, "stop releases pending upload data")
                check(fixture.flow.reads == 1, "stop does not rearm packetFlow")
            }
        }
        do {
            let fixture = Fixture()
            fixture.queue.sync { fixture.pump.stop() }
            fixture.deliver([packet(0)])
            fixture.queue.sync { check(fixture.pump.sent == 0, "late packetFlow completion after stop cannot send") }
        }
    }

    private static func testDownstreamBatch() {
        let fixture = Fixture()
        let packets = (0..<8).map { packet($0, size: 40) }
        // Block the pump queue until the whole input burst is available.
        fixture.queue.sync {
            for data in packets {
                let frame = PacketCodec.encode(data, family: AF_INET, mtu: 1400)!
                let sent = frame.withUnsafeBytes { send(fixture.peer, $0.baseAddress, $0.count, 0) }
                check(sent == frame.count, "prepare downstream burst")
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while fixture.queue.sync(execute: { fixture.pump.received < 8 }) && Date() < deadline { usleep(1000) }
        fixture.queue.sync {
            check(fixture.flow.writes == [packets], "deliver a downstream burst with one packetFlow write")
            check(fixture.pump.received == 8 && fixture.pump.diagnostics.bytesFromTunnel == 320, "count batched download packets and bytes")
            fixture.flow.acceptWrites = false
            let frame = PacketCodec.encode(packet(9, size: 40), family: AF_INET, mtu: 1400)!
            _ = frame.withUnsafeBytes { send(fixture.peer, $0.baseAddress, $0.count, 0) }
        }
        let failureDeadline = Date().addingTimeInterval(2)
        while fixture.queue.sync(execute: { fixture.pump.diagnostics.deliveryDrops == 0 }) && Date() < failureDeadline { usleep(1000) }
        fixture.queue.sync {
            check(fixture.pump.received == 8 && fixture.pump.diagnostics.deliveryDrops == 1, "a failed system write is not reported as delivery")
        }
    }

    private static func testFilteringAndSettingsChange() {
        let fixture = Fixture()
        fixture.queue.sync { fixture.pump.blocksIPv6 = true }
        var ipv6 = Data(repeating: 0, count: 40); ipv6[0] = 0x60
        fixture.deliver([ipv6], family: AF_INET6)
        fixture.deliver([Data([0x45])])
        fixture.queue.sync {
            let metrics = fixture.pump.diagnostics
            check(metrics.policyDrops == 1 && metrics.invalidPacketDrops == 1, "IPv6 policy discards are distinguishable from malformed packets")
            check(metrics.uploadBackpressureEvents == 0, "filtering must not be reported as congestion")
        }
        fixture.deliver((0..<64).map { packet($0) })
        let beforeMTUChange = fixture.queue.sync { () -> UInt64 in
            fixture.pump.mtu = 1200
            return fixture.pump.sent
        }
        while fixture.receive() != nil {}
        let deadline = Date().addingTimeInterval(2)
        while fixture.queue.sync(execute: { fixture.pump.diagnostics.queuedPackets > 0 }) && Date() < deadline { usleep(1000) }
        fixture.queue.sync {
            check(fixture.pump.sent == beforeMTUChange, "queued packets exceeding a changed MTU cannot be truncated by the engine")
            check(fixture.pump.diagnostics.invalidPacketDrops == 1 + 64 - beforeMTUChange, "MTU-related discards remain observable")
        }
    }
}
