package dev.hotfixruntime.android_spike

import android.content.pm.ApplicationInfo
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.StringCodec
import java.io.File

class MainActivity : FlutterActivity() {
    private var selectedRoot: File? = null

    private fun selectRoot(): File {
        selectedRoot?.let { return it }
        // Android's app mount namespace can alias /data/user/0 to /data/data.
        // Resolve only this trusted system base; native I/O still rejects links.
        val appFiles = filesDir.canonicalFile
        val defaultRoot = File(appFiles, "hotfix")
        val testCase = intent.getStringExtra(TEST_CASE_EXTRA)
        val root = if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            defaultRoot
        } else {
            when (testCase) {
                "baseline", "valid", "invalid-signature", "wrong-baseline" ->
                    File(appFiles, "hotfix-device/$testCase")
                else -> defaultRoot
            }
        }
        selectedRoot = root
        return root
    }

    override fun getDartEntrypointArgs(): List<String>? {
        val root = selectRoot()
        val inbox = File(root, "inbox")
        val patch = File(inbox, "patch.bytecode")
        val manifest = File(inbox, "manifest.json")
        val store = File(root, "store")
        Log.i(TAG, "bootstrap root=${root.path}, patch=${patch.exists()}, manifest=${manifest.exists()}")
        return if (!patch.exists() && !manifest.exists() && !store.exists()) {
            null
        } else {
            listOf(patch.path, manifest.path, store.path, "auto")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val root = selectRoot()
        val resultFile = File(root, "result.txt")
        resultFile.delete()
        BasicMessageChannel<String>(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
            StringCodec.INSTANCE,
        ).setMessageHandler { message, reply ->
            if (message != null) {
                Log.i(TAG, message)
                root.mkdirs()
                resultFile.writeText(message)
            }
            reply.reply(null)
        }
    }

    private companion object {
        const val CHANNEL = "hotfix/runtime-smoke"
        const val TAG = "HotfixRuntime"
        const val TEST_CASE_EXTRA = "hotfix_test_case"
    }
}
