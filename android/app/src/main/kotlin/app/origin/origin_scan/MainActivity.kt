package app.origin.origin_scan

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.WindowManager
import com.google.ar.core.Config
import com.google.ar.core.Session
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

class MainActivity : FlutterActivity() {
    private var capture: DepthCapture? = null
    private var eventSink: EventChannel.EventSink? = null
    private var permissionResult: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "app.origin/capture").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "capabilities" -> result.success(inspectDepth())
                    "requestCapabilities" -> {
                        if (
                            checkSelfPermission(Manifest.permission.CAMERA) ==
                                PackageManager.PERMISSION_GRANTED
                        )
                            result.success(inspectDepth())
                        else if (permissionResult != null)
                            result.error(
                                "busy",
                                "A camera permission request is already open.",
                                null,
                            )
                        else {
                            permissionResult = result
                            requestPermissions(arrayOf(Manifest.permission.CAMERA), 704)
                        }
                    }
                    "start" -> {
                        val view =
                            capture ?: throw IllegalStateException("Capture view is not ready.")
                        val path =
                            call.argument<String>("directory")
                                ?: throw IllegalArgumentException("Missing directory.")
                        val dir = File(path).canonicalFile
                        val base = File(filesDir, "flutter/ORIGIN Scan/pending").canonicalPath
                        // path_provider Android documents lives under app_flutter, not
                        // files/flutter.
                        val flutterBase =
                            File(applicationInfo.dataDir, "app_flutter/ORIGIN Scan/pending")
                                .canonicalPath
                        require(
                            dir.path.startsWith(flutterBase + File.separator) ||
                                dir.path.startsWith(base + File.separator)
                        ) {
                            "Invalid journal directory."
                        }
                        view.start(
                            dir,
                            call.argument<String>("quality") ?: "balanced",
                            call.argument<Boolean>("retainRaw") ?: true,
                        )
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    "pause" -> {
                        capture?.pauseCapture()
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    "resume" -> {
                        capture?.resumeCapture()
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    "finish" -> {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        val active = capture
                        if (active == null) result.success(null)
                        else
                            active.finish { error ->
                                if (error == null) result.success(null)
                                else result.error("capture", error, null)
                            }
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("capture", e.message ?: e.javaClass.simpleName, null)
            }
        }
        EventChannel(messenger, "app.origin/capture-events")
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                        eventSink = events
                    }

                    override fun onCancel(arguments: Any?) {
                        eventSink = null
                    }
                }
            )
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "app.origin/capture-view",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                    val view =
                        DepthCapture(this@MainActivity) { data ->
                            main.post { eventSink?.success(data) }
                        }
                    capture = view
                    return object : PlatformView {
                        override fun getView(): View = view

                        override fun dispose() {
                            view.close()
                            if (capture === view) capture = null
                        }
                    }
                }
            },
        )
        flutterEngine.platformViewsController.registry.registerViewFactory(
            "app.origin/viewer",
            object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
                override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
                    GeometryPlatformView(context, viewId, messenger)
            },
        )
    }

    @Suppress("DEPRECATION")
    private fun inspectDepth(): Map<String, Any> {
        val source = "ARCore estimated depth (may include hardware ToF)"
        try {
            packageManager.getPackageInfo("com.google.ar.core", 0)
        } catch (_: PackageManager.NameNotFoundException) {
            return mapOf(
                "supported" to false,
                "source" to source,
                "reason" to
                    "Google Play Services for AR is not installed. Install it before field work, or import a scan. No depth support has been detected.",
            )
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            return mapOf(
                "supported" to false,
                "needsPermission" to true,
                "source" to source,
                "reason" to
                    "Check device depth support. Camera permission is needed to inspect this device; no capture starts during the check.",
            )
        return try {
            val session = Session(this)
            try {
                val supported = session.isDepthModeSupported(Config.DepthMode.AUTOMATIC)
                mapOf(
                    "supported" to supported,
                    "source" to source,
                    "reason" to
                        if (supported) ""
                        else
                            "ARCore Depth is unavailable on this device. Import a local scan instead.",
                )
            } finally {
                session.close()
            }
        } catch (e: Exception) {
            mapOf(
                "supported" to false,
                "source" to source,
                "reason" to
                    "Depth unavailable: ${e.message}. Update Google Play Services for AR before field work, or import a scan.",
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 704) {
            val result = permissionResult
            permissionResult = null
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
                result?.success(inspectDepth())
            else
                result?.success(
                    mapOf(
                        "supported" to false,
                        "needsPermission" to true,
                        "source" to "ARCore depth",
                        "reason" to
                            "Camera permission was denied. Enable it in Android Settings to check depth support. Import remains available.",
                    )
                )
        }
    }

    override fun onPause() {
        capture?.pauseCapture()
        super.onPause()
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_RUNNING_LOW) capture?.memoryPressure()
    }
}
