package com.github.lingyan000.fluxdo

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.RouteInfo
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress

/** 只读取本应用默认网络公布的路由，不绑定网络、不发包，也不对域名做二次解析。 */
internal object NetworkRouteChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, "com.fluxdo/network_route")
        channel.setMethodCallHandler { call, result ->
            if (call.method != "snapshot") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val addresses = call.arguments as? List<*>
            if (addresses == null || addresses.size > 16 ||
                addresses.any { it !is ByteArray || it.size !in setOf(4, 16) }) {
                result.error("invalid", "需要数字地址", null)
                return@setMethodCallHandler
            }
            try {
                val cm = context.getSystemService(ConnectivityManager::class.java)
                val network = cm.activeNetwork
                if (network == null) {
                    result.success("appNetwork=none")
                    return@setMethodCallHandler
                }
                val caps = cm.getNetworkCapabilities(network)
                val vpn = caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                val routes = cm.getLinkProperties(network)?.routes
                val matches = addresses.map { bytes ->
                    val ip = InetAddress.getByAddress(bytes as ByteArray)
                    val route = routes?.filter { it.matches(ip) }?.maxByOrNull { it.destination.prefixLength }
                    when {
                        routes == null -> "unknown"
                        route == null -> "no-match"
                        Build.VERSION.SDK_INT >= 33 && route.type == RouteInfo.RTN_THROW -> "excluded"
                        Build.VERSION.SDK_INT >= 33 && route.type == RouteInfo.RTN_UNREACHABLE -> "unreachable"
                        else -> "matched"
                    }
                }
                // 顺序对应 Dart 日志中的公网候选；本快照不能证明某个包已穿过 TUN。
                result.success("appDefaultVpn=${vpn ?: "unknown"} targetRoutes=${matches.joinToString(",")}")
            } catch (_: RuntimeException) {
                result.success("appNetwork=unknown")
            }
        }
    }
}
