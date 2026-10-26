package com.ayma.ayma_flutter

import android.Manifest
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
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
 * and the report card's "Save image" use to save into the device gallery
 * (MediaStore `Pictures/Ayma`) — a dozen lines here instead of a whole
 * gallery-saver plugin.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val MEDIA_SAVE_CHANNEL = "ayma/media_save"
        const val SHARE_CHANNEL = "ayma/share"
        const val PUSH_CHANNEL = "ayma/push"

        /** True while the app is on screen; [DmMessagingService] posts nothing then. */
        @Volatile
        var isResumed = false
    }

    private var pushChannel: MethodChannel? = null

    override fun onResume() {
        super.onResume()
        isResumed = true
    }

    override fun onPause() {
        isResumed = false
        super.onPause()
    }

    /** The DM-notification tap target carried by [intent], consumed once. */
    private fun takeDeepLink(intent: Intent?): String? {
        val link = intent?.getStringExtra(DmMessagingService.EXTRA_DEEP_LINK)
        intent?.removeExtra(DmMessagingService.EXTRA_DEEP_LINK)
        return link?.takeIf { it.isNotEmpty() }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeDeepLink(intent)?.let { pushChannel?.invokeMethod("onDeepLink", it) }
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
                    val aymaQuiet = call.argument<Boolean>("aymaQuiet") ?: false
                    val startTimeMillis = call.argument<Number>("startTimeMillis")
                    val intent = Intent(this, CallForegroundService::class.java).apply {
                        putExtra(CallForegroundService.EXTRA_STATUS, status)
                        putExtra(CallForegroundService.EXTRA_MUTED, muted)
                        putExtra(CallForegroundService.EXTRA_AYMA_QUIET, aymaQuiet)
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

        pushChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PUSH_CHANNEL
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialDeepLink" -> result.success(takeDeepLink(intent))
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SHARE_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "instagramStory" -> {
                    val path = call.argument<String>("path")
                    val appId = call.argument<String>("appId")
                    val contentUrl = call.argument<String>("contentUrl") ?: ""
                    if (path == null || appId == null) {
                        result.error("ARGS", "missing path or appId", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(shareToInstagramStory(path, appId, contentUrl))
                    } catch (e: Exception) {
                        result.error("STORY_FAILED", e.message, null)
                    }
                }
                "sendToApp" -> {
                    val path = call.argument<String>("path")
                    val packages = call.argument<List<String>>("packages") ?: emptyList()
                    val text = call.argument<String>("text") ?: ""
                    if (path == null) {
                        result.error("ARGS", "missing path", null)
                        return@setMethodCallHandler
                    }
                    try {
                        result.success(sendImageToApp(path, packages, text))
                    } catch (e: Exception) {
                        result.error("SEND_FAILED", e.message, null)
                    }
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
     * Opens Instagram's Story composer with the PNG at [path] as the
     * background. Reuses share_plus's FileProvider (its cache-dir paths cover
     * Dart's temp directory). Returns false when Instagram isn't installed.
     */
    private fun shareToInstagramStory(path: String, appId: String, contentUrl: String): Boolean {
        val uri = FileProvider.getUriForFile(
            this, "$packageName.fileprovider", File(path)
        )
        val intent = Intent("com.instagram.share.ADD_TO_STORY").apply {
            setDataAndType(uri, "image/png")
            if (appId.isNotEmpty()) putExtra("source_application", appId)
            if (contentUrl.isNotEmpty()) putExtra("content_url", contentUrl)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (intent.resolveActivity(packageManager) == null) return false
        grantUriPermission("com.instagram.android", uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        startActivity(intent)
        return true
    }

    /**
     * Sends the PNG at [path] (plus optional [text]) to the first installed
     * app in [packages] with a plain ACTION_SEND — the report card's
     * WhatsApp / Instagram targets (Instagram then offers Stories). Same
     * share_plus FileProvider as [shareToInstagramStory]. Returns false when
     * none of [packages] is installed, so Dart falls back to the share sheet.
     */
    private fun sendImageToApp(path: String, packages: List<String>, text: String): Boolean {
        val uri = FileProvider.getUriForFile(
            this, "$packageName.fileprovider", File(path)
        )
        for (pkg in packages) {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                if (text.isNotEmpty()) putExtra(Intent.EXTRA_TEXT, text)
                setPackage(pkg)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            if (intent.resolveActivity(packageManager) != null) {
                // The intent flag grants read access to the resolved activity,
                // but an explicit grant to the target package is more reliable
                // across OEMs (some drop the flag grant on a direct, non-chooser
                // startActivity) — without it the receiver gets a URI it can't
                // read and the image silently fails to attach.
                grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                startActivity(intent)
                return true
            }
        }
        return false
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
