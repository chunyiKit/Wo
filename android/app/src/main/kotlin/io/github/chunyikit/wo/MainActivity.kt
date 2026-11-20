package io.github.chunyikit.wo

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var localBridge: WoLocalBridge? = null
    private var mediaBridge: WoMediaBridge? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        localBridge?.close()
        localBridge = WoLocalBridge(this, messenger)
        mediaBridge = WoMediaBridge.attach(this, messenger)
    }
    @Deprecated("Activity result compatibility for scoped document picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (mediaBridge?.onActivityResult(requestCode, resultCode, data) != true) super.onActivityResult(requestCode, resultCode, data)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (mediaBridge?.onRequestPermissionsResult(requestCode, permissions, grantResults) != true) super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
    override fun onPause() { localBridge?.stop(); super.onPause() }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        localBridge?.close(); localBridge = null
        mediaBridge?.close(); mediaBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
