package com.ayma.ayma_flutter

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

/**
 * Caches this activity's [FlutterEngine] so [CallForegroundService] can call
 * back into the same running Dart isolate (never a second engine), and wires
 * the "ayma/call_ui" channel Dart's `CallBackgroundService` uses to start,
 * update, and stop that service (F4 — background call notification).
 *
 * Also hosts the tiny "ayma/media_save" channel the full-screen image viewer
 * uses to save a photo into the device gallery (MediaStore `Pictures/Ayma`) —
 * a dozen lines here instead of a whole gallery-saver plugin.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val MEDIA_SAVE_CHANNEL = "ayma/media_save"
    }

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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_SAVE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveImage" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val name = call.argument<String>("name")
                        ?: "ayma_${System.currentTimeMillis()}.jpg"
                    val mime = call.argument<String>("mime") ?: "image/jpeg"
                    if (bytes == null) {
                        result.error("ARGS", "missing image bytes", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(saveImageToGallery(bytes, name, mime))
                    } catch (e: SecurityException) {
                        result.error("PERMISSION", e.message, null)
                    } catch (e: Exception) {
                        result.error("SAVE_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Writes [bytes] as an image named [name] into the gallery under
     * `Pictures/Ayma` and returns that human-readable location. API 29+ goes
     * through scoped MediaStore (no permission); API 24–28 writes the public
     * Pictures directory, which needs WRITE_EXTERNAL_STORAGE — thrown as
     * [SecurityException] so Dart can request it and retry.
     */
    private fun saveImageToGallery(bytes: ByteArray, name: String, mime: String): String {
        val location = "Pictures/Ayma"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mime)
                put(
                    MediaStore.Images.Media.RELATIVE_PATH,
                    "${Environment.DIRECTORY_PICTURES}/Ayma"
                )
            }
            val uri = contentResolver.insert(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
            ) ?: throw IOException("MediaStore insert failed")
            contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                ?: throw IOException("MediaStore open failed")
        } else {
            if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED
            ) {
                throw SecurityException("WRITE_EXTERNAL_STORAGE not granted")
            }
            val dir = File(
                Environment.getExternalStoragePublicDirectory(
                    Environment.DIRECTORY_PICTURES
                ),
                "Ayma"
            )
            if (!dir.exists() && !dir.mkdirs()) throw IOException("mkdirs failed")
            File(dir, name).writeBytes(bytes)
            MediaScannerConnection.scanFile(
                this, arrayOf(File(dir, name).absolutePath), arrayOf(mime), null
            )
        }
        return location
    }

    private fun startCallService(intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
