package io.github.matthewreed303.camstation

import android.content.Context
import android.media.MediaCodecList
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The only native code in CamStation (brief §2: keep Kotlin minimal).
 * - nativeLibraryDir: where the packaged go2rtc (libgo2rtc.so) is extracted;
 *   it is the one app location Android still allows executing from.
 * - androidRelease: passed to the engine as ANDROID_VERSION (WebRTC on 11+).
 * - Multicast lock: without it Android drops multicast/broadcast on Wi-Fi,
 *   so ONVIF and DVRIP discovery would find nothing.
 * - deviceInfo: model and video decoder limits, for the diagnostics log
 *   (e.g. an older phone whose decoder stops at 1080p can't play 4K).
 */
class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "camstation/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "nativeLibraryDir" -> result.success(applicationInfo.nativeLibraryDir)
                    // Android release ("14"); the engine needs it on Android 11+.
                    "androidRelease" -> result.success(android.os.Build.VERSION.RELEASE)
                    "deviceInfo" -> result.success(deviceInfo())
                    "acquireMulticastLock" -> {
                        if (multicastLock?.isHeld != true) {
                            val wifi = applicationContext
                                .getSystemService(Context.WIFI_SERVICE) as WifiManager
                            multicastLock = wifi.createMulticastLock("camstation-discovery").apply {
                                setReferenceCounted(false)
                                acquire()
                            }
                        }
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        multicastLock?.takeIf { it.isHeld }?.release()
                        multicastLock = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** One line per H.264/H.265 decoder: name and largest frame size. */
    private fun deviceInfo(): String {
        val lines = mutableListOf(
            "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE} " +
                "(API ${Build.VERSION.SDK_INT}), ${Build.SUPPORTED_ABIS.joinToString("/")}"
        )
        try {
            for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                if (info.isEncoder) continue
                for (type in info.supportedTypes) {
                    val t = type.lowercase()
                    if (t != "video/avc" && t != "video/hevc") continue
                    val v = info.getCapabilitiesForType(type).videoCapabilities ?: continue
                    val w = v.supportedWidths.upper
                    val h = v.supportedHeights.upper
                    val uhd = v.isSizeSupported(3840, 2160)
                    val fhd = v.isSizeSupported(1920, 1080)
                    lines.add(
                        "${t.removePrefix("video/")} ${info.name}: up to ${w}x$h" +
                            " (1080p ${if (fhd) "yes" else "no"}, 4K ${if (uhd) "yes" else "no"})"
                    )
                }
            }
        } catch (e: Exception) {
            lines.add("decoders: ${e.message}")
        }
        return lines.joinToString("\n")
    }

    override fun onDestroy() {
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
        super.onDestroy()
    }
}
