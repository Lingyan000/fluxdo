package com.fluxdo.fingerprintprobe;

import java.net.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;

// 仅用于 Android 模拟器诊断：adb reverse 只转发 TCP，UDP 原样送到模拟器宿主。
// 每个浏览器源端口独立上游 socket，最多 8 条映射，不混合不同 QUIC 连接的报文。
final class UdpBridge implements AutoCloseable {
    private final DatagramSocket listener;
    private final DatagramSocket listener6;
    private final InetSocketAddress destination;
    private final ConcurrentHashMap<SocketAddress, DatagramSocket> flows = new ConcurrentHashMap<>();
    private volatile boolean closed;
    final AtomicLong sent = new AtomicLong();
    final AtomicLong received = new AtomicLong();
    volatile String error;
    UdpBridge(int port) throws Exception {
        this(port, new InetSocketAddress("10.0.2.2", port));
    }
    // 测试可指定本机回显端点，正式模拟器仍固定转发到其宿主。
    UdpBridge(int port, InetSocketAddress destination) throws Exception {
        this.destination = destination;
        listener = new DatagramSocket(new InetSocketAddress("127.0.0.1", port));
        try {
            listener6 = new DatagramSocket(new InetSocketAddress("::1", listener.getLocalPort()));
        } catch (Exception error) {
            listener.close();
            throw error;
        }
        new Thread(() -> run(listener), "probe-udp-listener").start();
        new Thread(() -> run(listener6), "probe-udp-listener6").start();
    }
    int localPort() { return listener.getLocalPort(); }
    private void run(DatagramSocket incoming) {
        try {
            while (!closed) {
                DatagramPacket packet = new DatagramPacket(new byte[65535], 65535);
                incoming.receive(packet);
                SocketAddress source = packet.getSocketAddress();
                DatagramSocket upstream;
                synchronized (flows) {
                  if (closed) return;
                  upstream = flows.get(source);
                  if (upstream == null) {
                    if (flows.size() >= 8) continue;
                    upstream = new DatagramSocket();
                    upstream.connect(destination);
                    upstream.setSoTimeout(15000);
                    flows.put(source, upstream);
                    DatagramSocket flow = upstream;
                    new Thread(() -> replies(incoming, source, flow), "probe-udp-replies").start();
                }
                }
                upstream.send(new DatagramPacket(packet.getData(), packet.getLength()));
                sent.incrementAndGet();
            }
        } catch (Exception e) { if (!closed) error = e.toString(); }
    }
    private void replies(DatagramSocket incoming, SocketAddress source, DatagramSocket upstream) {
        try {
            while (!closed) {
                DatagramPacket packet = new DatagramPacket(new byte[65535], 65535);
                upstream.receive(packet);
                incoming.send(new DatagramPacket(packet.getData(), packet.getLength(), source));
                received.incrementAndGet();
            }
        } catch (SocketTimeoutException ignored) {
        } catch (Exception e) { if (!closed) error = e.toString(); }
        finally { flows.remove(source, upstream); upstream.close(); }
    }
    @Override public void close() {
        closed = true;
        listener.close();
        listener6.close();
        synchronized (flows) {
            for (DatagramSocket socket : flows.values()) socket.close();
            flows.clear();
        }
    }
}
