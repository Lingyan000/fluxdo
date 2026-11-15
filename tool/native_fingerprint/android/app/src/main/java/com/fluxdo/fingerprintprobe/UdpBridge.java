package com.fluxdo.fingerprintprobe;

import java.net.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

// 仅用于 Android 模拟器诊断：adb reverse 只转发 TCP，UDP 原样送到模拟器宿主。
// 每个浏览器源端口独立上游 socket，最多 8 条映射，不混合不同 QUIC 连接的报文。
final class UdpBridge implements AutoCloseable {
    private final DatagramSocket listener;
    private final int port;
    private final ConcurrentHashMap<SocketAddress, DatagramSocket> flows = new ConcurrentHashMap<>();
    private volatile boolean closed;
    final AtomicLong sent = new AtomicLong();
    final AtomicLong received = new AtomicLong();
    volatile String error;
    UdpBridge(int port) throws Exception {
        this.port = port;
        listener = new DatagramSocket(new InetSocketAddress("127.0.0.1", port));
        new Thread(this::run, "probe-udp-listener").start();
    }
    private void run() {
        try {
            while (!closed) {
                DatagramPacket packet = new DatagramPacket(new byte[65535], 65535);
                listener.receive(packet);
                SocketAddress source = packet.getSocketAddress();
                DatagramSocket upstream = flows.get(source);
                if (upstream == null) {
                    if (flows.size() >= 8) continue;
                    upstream = new DatagramSocket();
                    upstream.connect(InetAddress.getByName("10.0.2.2"), port);
                    upstream.setSoTimeout(15000);
                    flows.put(source, upstream);
                    DatagramSocket flow = upstream;
                    new Thread(() -> replies(source, flow), "probe-udp-replies").start();
                }
                upstream.send(new DatagramPacket(packet.getData(), packet.getLength()));
                sent.incrementAndGet();
            }
        } catch (Exception e) { if (!closed) error = e.toString(); }
    }
    private void replies(SocketAddress source, DatagramSocket upstream) {
        try {
            while (!closed) {
                DatagramPacket packet = new DatagramPacket(new byte[65535], 65535);
                upstream.receive(packet);
                listener.send(new DatagramPacket(packet.getData(), packet.getLength(), source));
                received.incrementAndGet();
            }
        } catch (SocketTimeoutException ignored) {
        } catch (Exception e) { if (!closed) error = e.toString(); }
        finally { flows.remove(source, upstream); upstream.close(); }
    }
    @Override public void close() {
        closed = true;
        listener.close();
        for (DatagramSocket socket : flows.values()) socket.close();
        flows.clear();
    }
}
