package io.github.matthewreed303.camstation

import android.content.Context
import android.net.wifi.WifiManager
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

    override fun onDestroy() {
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
        super.onDestroy()
    }
}
