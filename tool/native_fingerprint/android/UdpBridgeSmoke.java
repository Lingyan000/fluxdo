package com.fluxdo.fingerprintprobe;

import java.net.*;
import java.util.*;

// 用真实 UDP 验证两种回环地址的字节透明转发、连接隔离和端口释放。
public final class UdpBridgeSmoke {
    public static void main(String[] args) throws Exception {
        int port;
        Set<Integer> peers = Collections.synchronizedSet(new HashSet<>());
        try (DatagramSocket server = new DatagramSocket(new InetSocketAddress("127.0.0.1", 0));
             UdpBridge bridge = new UdpBridge(0, new InetSocketAddress("127.0.0.1", server.getLocalPort()))) {
            server.setSoTimeout(5000);
            port = bridge.localPort();
            Thread echo = new Thread(() -> {
                try {
                    for (int i = 0; i < 2; i++) {
                        DatagramPacket packet = new DatagramPacket(new byte[2048], 2048);
                        server.receive(packet);
                        peers.add(packet.getPort());
                        server.send(packet);
                    }
                } catch (Exception error) { throw new RuntimeException(error); }
            });
            echo.start();
            for (String host : new String[]{"127.0.0.1", "::1"}) {
                try (DatagramSocket client = new DatagramSocket(new InetSocketAddress(host, 0))) {
                    client.setSoTimeout(5000);
                    byte[] payload = new byte[1200];
                    new Random(host.hashCode()).nextBytes(payload);
                    client.send(new DatagramPacket(payload, payload.length, InetAddress.getByName(host), port));
                    DatagramPacket reply = new DatagramPacket(new byte[2048], 2048);
                    client.receive(reply);
                    if (!Arrays.equals(payload, Arrays.copyOf(reply.getData(), reply.getLength()))) throw new AssertionError("changed bytes");
                }
            }
            echo.join(6000);
            if (echo.isAlive() || peers.size() != 2 || bridge.error != null) throw new AssertionError("flow isolation failed");
        }
        try (DatagramSocket v4 = new DatagramSocket(new InetSocketAddress("127.0.0.1", port));
             DatagramSocket v6 = new DatagramSocket(new InetSocketAddress("::1", port))) {
            System.out.println("{\"ipv4\":true,\"ipv6\":true,\"distinct_upstream_flows\":2,\"ports_released\":true}");
        }
    }
}
