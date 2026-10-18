package com.k1taproject.howdoi

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.io.File

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val inbox get() = getSharedPreferences("map_share", MODE_PRIVATE)
    private fun receive(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND || intent.type != "text/plain") return
        val text = listOfNotNull(intent.getStringExtra(Intent.EXTRA_SUBJECT),
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()).joinToString("\n")
        if (text.isNotBlank() && text.length <= 20000) {
            inbox.edit().putString("text", text).putString("id", UUID.randomUUID().toString()).commit()
            channel?.invokeMethod("changed", null)
        }
        intent.action = null
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "howdoi/map_share")
        channel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "peek" -> result.success(mapOf("id" to inbox.getString("id", null), "text" to inbox.getString("text", null)))
                "ack" -> {
                    if (call.arguments == inbox.getString("id", null)) inbox.edit().clear().commit()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // Old Android inline maps used only this app-private tile cache.
        val oldTiles = File(cacheDir, "fm_cache")
        if (oldTiles.canonicalFile.parentFile == cacheDir.canonicalFile) oldTiles.deleteRecursively()
        receive(intent)
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }
}
