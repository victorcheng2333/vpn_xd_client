import Foundation
import Darwin

enum PacketCodec {
    static func canForward(family: Int32, blocksIPv6: Bool) -> Bool {
        family == AF_INET || (family == AF_INET6 && !blocksIPv6)
    }
    static func valid(_ packet: Data, family: Int32, mtu: Int) -> Bool {
        guard packet.count <= mtu, let first = packet.first else { return false }
        let bytes = [UInt8](packet.prefix(6))
        if family == AF_INET {
            guard packet.count >= 20, first >> 4 == 4, Int(first & 15) * 4 >= 20,
                  Int(first & 15) * 4 <= packet.count else { return false }
            return (Int(bytes[2]) << 8 | Int(bytes[3])) == packet.count
        }
        if family == AF_INET6 {
            guard packet.count >= 40, first >> 4 == 6 else { return false }
            return (Int(bytes[4]) << 8 | Int(bytes[5])) + 40 == packet.count
        }
        return false
    }
    static func encode(_ packet: Data, family: Int32, mtu: Int) -> Data? {
        guard valid(packet, family: family, mtu: mtu) else { return nil }
        let value = UInt32(family)
        var result = Data([UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
        result.append(packet)
        return result
    }
    static func decode(_ datagram: Data, mtu: Int) -> (Data, Int32)? {
        guard datagram.count >= 4 else { return nil }
        let family = datagram.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard family == UInt32(AF_INET) || family == UInt32(AF_INET6) else { return nil }
        let packet = Data(datagram.dropFirst(4))
        return valid(packet, family: Int32(family), mtu: mtu) ? (packet, Int32(family)) : nil
    }
}
