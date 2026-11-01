package com.adeeteya.classipod

import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var permissionResult: MethodChannel.Result? = null
    private val localPermission = "android.permission.ACCESS_LOCAL_NETWORK"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "classipod/sonos")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestLocalNetwork" -> {
                        if (Build.VERSION.SDK_INT < 37 || applicationInfo.targetSdkVersion < 37 ||
                            checkSelfPermission(localPermission) == PackageManager.PERMISSION_GRANTED) {
                            result.success(true)
                        } else if (permissionResult != null) {
                            result.success(false)
                        } else {
                            permissionResult = result
                            requestPermissions(arrayOf(localPermission), 3701)
                        }
                    }
                    "acquireMulticast" -> {
                        try {
                            if (multicastLock == null) {
                                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                                multicastLock = wifi.createMulticastLock("ClassipodSonos").apply {
                                    setReferenceCounted(false)
                                    acquire()
                                }
                            }
                            result.success(null)
                        } catch (_: SecurityException) {
                            result.error("permission", "Wi-Fi discovery permission denied", null)
                        }
                    }
                    "releaseMulticast" -> {
                        releaseMulticast()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 3701) {
            permissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            permissionResult = null
        }
    }

    private fun releaseMulticast() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    override fun onDestroy() {
        releaseMulticast()
        permissionResult?.success(false)
        permissionResult = null
        super.onDestroy()
    }
}
