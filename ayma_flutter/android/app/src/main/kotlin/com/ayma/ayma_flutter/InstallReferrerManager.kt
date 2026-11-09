package com.ayma.ayma_flutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Reads the Google Play install referrer on Android over the "ayma/install_referrer"
 * MethodChannel so Ayma can auto-open shared profiles after install.
 */
class InstallReferrerManager(
    private val context: Context,
    private val messenger: BinaryMessenger
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL_NAME = "ayma/install_referrer"
        private const val TAG = "InstallReferrerManager"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null

    fun attach() {
        channel = MethodChannel(messenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(this)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getInstallReferrer" -> readInstallReferrer(result)
            else -> result.notImplemented()
        }
    }

    private fun readInstallReferrer(result: MethodChannel.Result) {
        val completed = AtomicBoolean(false)

        fun reply(referrer: String?) {
            if (completed.compareAndSet(false, true)) {
                mainHandler.post {
                    try {
                        result.success(referrer)
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed to send install referrer result: ${e.message}")
                    }
                }
            }
        }

        try {
            val client = InstallReferrerClient.newBuilder(context).build()
            client.startConnection(object : InstallReferrerStateListener {
                override fun onInstallReferrerSetupFinished(responseCode: Int) {
                    if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                        try {
                            val referrer = client.installReferrer?.installReferrer
                            reply(referrer)
                        } catch (e: Exception) {
                            Log.w(TAG, "Error getting referrer details: ${e.message}")
                            reply(null)
                        } finally {
                            try { client.endConnection() } catch (_: Exception) {}
                        }
                    } else {
                        Log.d(TAG, "Install referrer setup returned code: $responseCode")
                        try { client.endConnection() } catch (_: Exception) {}
                        reply(null)
                    }
                }

                override fun onInstallReferrerServiceDisconnected() {
                    Log.d(TAG, "Install referrer service disconnected")
                    reply(null)
                }
            })
        } catch (e: Exception) {
            Log.w(TAG, "Failed to start install referrer connection: ${e.message}")
            reply(null)
        }
    }
}
