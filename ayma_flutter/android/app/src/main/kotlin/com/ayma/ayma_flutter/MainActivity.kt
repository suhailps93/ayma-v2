package com.ayma.ayma_flutter

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * Caches this activity's [FlutterEngine] so [CallForegroundService] can call
 * back into the same running Dart isolate (never a second engine), and wires
 * the "ayma/call_ui" channel Dart's `CallBackgroundService` uses to start,
 * update, and stop that service (F4 — background call notification).
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(
            CallForegroundService.ENGINE_CACHE_ID,
            flutterEngine
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CallForegroundService.METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start", "update" -> {
                    val status = call.argument<String>("status")
                        ?: "Voice call"
                    val muted = call.argument<Boolean>("muted") ?: false
                    val startTimeMillis = call.argument<Number>("startTimeMillis")
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        putExtra(CallForegroundService.EXTRA_STATUS, status)
                        putExtra(CallForegroundService.EXTRA_MUTED, muted)
                        if (startTimeMillis != null) {
                            putExtra(
                                CallForegroundService.EXTRA_START_TIME,
                                startTimeMillis.toLong()
                            )
                        }
                    }
                    startCallService(intent)
                    result.success(null)
                }
                "stop" -> {
                    startCallService(
                        Intent(this, CallForegroundService::class.java)
                            .setAction(CallForegroundService.ACTION_STOP)
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startCallService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
