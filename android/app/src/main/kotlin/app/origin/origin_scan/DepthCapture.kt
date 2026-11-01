package app.origin.origin_scan

import android.app.Activity
import android.opengl.GLES11Ext
import android.opengl.GLES30 as GL
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import com.google.ar.core.*
import com.google.ar.core.exceptions.NotYetAvailableException
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.*
import org.json.JSONArray
import org.json.JSONObject

internal fun writeAtomic(file: File, bytes: ByteArray) {
    val atomic = AtomicFile(file)
    val stream = atomic.startWrite()
    try {
        stream.write(bytes)
        atomic.finishWrite(stream)
    } catch (e: Exception) {
        atomic.failWrite(stream)
        throw e
    }
}

internal fun writePointChunk(file: File, points: FloatArray, count: Int) {
    val header =
        "ply\nformat binary_little_endian 1.0\ncomment units=metres; right-handed Y-up\nelement vertex $count\nproperty float x\nproperty float y\nproperty float z\nelement face 0\nproperty list uchar uint vertex_indices\nend_header\n"
            .toByteArray()
    val bytes =
        ByteBuffer.allocate(header.size + count * 12).order(ByteOrder.LITTLE_ENDIAN).put(header)
    for (i in 0 until count * 3) bytes.putFloat(points[i])
    writeAtomic(file, bytes.array())
}

internal class DepthCapture(
    private val activity: Activity,
    private val emit: (Map<String, Any>) -> Unit,
) : GLSurfaceView(activity), GLSurfaceView.Renderer {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var session: Session? = null
    @Volatile private var capturing = false
    private var directory: File? = null
    private var retainRaw = true
    private var voxel = .02f
    private val occupied = HashSet<Long>()
    private var points = FloatArray(0)
    private var total = 0
    private var pending = FloatArray(120000 * 3)
    private var pendingCount = 0
    private var chunk = 0
    private var lastDepth = 0L
    private var lastSample = 0L
    private var lastFlush = 0L
    private var rawBytes = 0L
    private var segments = 1
    private var lastTracking = "initializing"
    private var trackingLosses = 0
    private var cameraTexture = 0
    private var backgroundProgram = 0
    private var textureSet = false
    private val quad = floats(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val uv = floats(FloatArray(8))
    private val gpu = MeshGpu()
    private var previewDirty = false
    private var width = 1
    private var height = 1
    @Volatile private var rendererReady = false

    init {
        setEGLContextClientVersion(3)
        preserveEGLContextOnPause = true
        setRenderer(this)
        renderMode = RENDERMODE_CONTINUOUSLY
    }

    fun start(dir: File, quality: String, raw: Boolean) {
        check(session == null) { "A capture is already active." }
        check(rendererReady) {
            "The device could not initialize the camera renderer. Return to Home and try again."
        }
        val s = Session(activity)
        try {
            check(s.isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                "ARCore Depth is unsupported on this device."
            }
            s.configure(
                Config(s).apply {
                    depthMode = Config.DepthMode.AUTOMATIC
                    focusMode = Config.FocusMode.AUTO
                    lightEstimationMode = Config.LightEstimationMode.DISABLED
                    updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                    cloudAnchorMode = Config.CloudAnchorMode.DISABLED
                    geospatialMode = Config.GeospatialMode.DISABLED
                }
            )
            directory = dir
            retainRaw = raw
            voxel =
                when (quality) {
                    "detail" -> .01f
                    "large" -> .05f
                    else -> .02f
                }
            points = FloatArray(2_000_000 * 3)
            occupied.clear()
            total = 0
            pendingCount = 0
            chunk = 0
            lastDepth = 0
            lastSample = 0
            lastFlush = System.nanoTime()
            rawBytes = 0
            segments = 1
            trackingLosses = 0
            textureSet = false
            session = s
            s.resume()
            capturing = true
            onResume()
        } catch (e: Exception) {
            session = null
            s.close()
            throw e
        }
    }

    fun pauseCapture() {
        if (session == null) return
        capturing = false
        // Stop frame updates before ARCore is paused; journal flush runs on the same GL queue.
        queueEvent {
            try {
                flush()
                status("Capture paused")
            } catch (e: Exception) {
                fail(e.message ?: "Storage write failed")
            }
        }
        onPause()
        session?.pause()
    }

    fun resumeCapture() {
        val s = session ?: throw IllegalStateException("Start a scan first.")
        s.resume()
        capturing = true
        segments++
        onResume()
    }

    fun finish(done: (String?) -> Unit) {
        if (session == null) {
            done(null)
            return
        }
        capturing = false
        // A paused GL thread is resumed only to flush journal state; no frames are accumulated.
        onResume()
        queueEvent {
            var error: String? = null
            try {
                flush()
                writeQuality()
                status("Scan complete")
            } catch (e: Exception) {
                error = e.message
            }
            main.post {
                onPause()
                session?.pause()
                session?.close()
                session = null
                points = FloatArray(0)
                occupied.clear()
                done(error)
            }
        }
    }

    fun close() {
        if (session != null) finish {} else onPause()
    }

    fun memoryPressure() {
        capturing = false
        queueEvent {
            try {
                flush()
            } catch (_: Exception) {}
            status("Memory pressure — finish this segment")
        }
    }

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        try {
            GL.glClearColor(32 / 255f, 38 / 255f, 36 / 255f, 1f)
            GL.glEnable(GL.GL_DEPTH_TEST)
            gpu.init()
            previewDirty = true
            val textures = IntArray(1)
            GL.glGenTextures(1, textures, 0)
            cameraTexture = textures[0]
            GL.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexture)
            GL.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GL.GL_TEXTURE_MIN_FILTER,
                GL.GL_LINEAR,
            )
            GL.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GL.GL_TEXTURE_MAG_FILTER,
                GL.GL_LINEAR,
            )
            backgroundProgram =
                program(
                    "attribute vec2 aPosition;attribute vec2 aUv;varying mediump vec2 uv;void main(){gl_Position=vec4(aPosition,0.0,1.0);uv=aUv;}",
                    "#extension GL_OES_EGL_image_external : require\nprecision mediump float;uniform samplerExternalOES uCamera;varying mediump vec2 uv;void main(){gl_FragColor=texture2D(uCamera,uv);}",
                )
            textureSet = false
            rendererReady = true
        } catch (e: Exception) {
            rendererReady = false
            fail("This device could not initialize camera rendering: ${e.message}")
        }
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        width = w
        height = h
        GL.glViewport(0, 0, w, h)
    }

    @Suppress("DEPRECATION")
    override fun onDrawFrame(gl: GL10?) {
        GL.glClear(GL.GL_COLOR_BUFFER_BIT or GL.GL_DEPTH_BUFFER_BIT)
        if (!rendererReady) return
        val s = session ?: return
        try {
            if (!textureSet) {
                s.setCameraTextureNames(intArrayOf(cameraTexture))
                textureSet = true
            }
            s.setDisplayGeometry(activity.windowManager.defaultDisplay.rotation, width, height)
            val frame = s.update()
            if (frame.timestamp == 0L) return
            drawCamera(frame)
            val camera = frame.camera
            if (camera.trackingState != TrackingState.TRACKING) {
                if (lastTracking == "tracking") trackingLosses++
                lastTracking = "limited"
                status(
                    if (camera.trackingFailureReason == TrackingFailureReason.EXCESSIVE_MOTION)
                        "Move slowly"
                    else "Tracking lost — return to a textured, familiar area"
                )
                return
            }
            lastTracking = "tracking"
            val now = System.nanoTime()
            if (capturing && now - lastSample > 250_000_000L) {
                lastSample = now
                accumulate(frame)
            }
            if (previewDirty) {
                val step = max(1, (total + 299999) / 300000)
                val preview = FloatArray(((total + step - 1) / step) * 3)
                var j = 0
                for (i in 0 until total step step) for (k in 0..2) preview[j++] = points[i * 3 + k]
                gpu.upload(MeshData(preview))
                previewDirty = false
            }
            val view = FloatArray(16)
            val projection = FloatArray(16)
            val mvp = FloatArray(16)
            camera.getViewMatrix(view, 0)
            camera.getProjectionMatrix(projection, 0, .05f, 100f)
            Matrix.multiplyMM(mvp, 0, projection, 0, view, 0)
            gpu.draw(mvp, "points")
            if (capturing && now - lastFlush > 2_000_000_000L) {
                flush()
                lastFlush = now
                status("Move slowly · revisit missing surfaces")
            }
        } catch (_: NotYetAvailableException) {
            status("Move slowly to estimate depth")
        } catch (e: Exception) {
            fail(e.message ?: "Camera or depth capture failed")
        }
    }

    private fun drawCamera(frame: Frame) {
        quad.position(0)
        uv.position(0)
        frame.transformCoordinates2d(
            Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES,
            quad,
            Coordinates2d.TEXTURE_NORMALIZED,
            uv,
        )
        GL.glDisable(GL.GL_DEPTH_TEST)
        GL.glDepthMask(false)
        GL.glUseProgram(backgroundProgram)
        val a = GL.glGetAttribLocation(backgroundProgram, "aPosition")
        val t = GL.glGetAttribLocation(backgroundProgram, "aUv")
        quad.position(0)
        uv.position(0)
        GL.glEnableVertexAttribArray(a)
        GL.glEnableVertexAttribArray(t)
        GL.glVertexAttribPointer(a, 2, GL.GL_FLOAT, false, 0, quad)
        GL.glVertexAttribPointer(t, 2, GL.GL_FLOAT, false, 0, uv)
        GL.glActiveTexture(GL.GL_TEXTURE0)
        GL.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, cameraTexture)
        GL.glUniform1i(GL.glGetUniformLocation(backgroundProgram, "uCamera"), 0)
        GL.glDrawArrays(GL.GL_TRIANGLE_STRIP, 0, 4)
        GL.glDisableVertexAttribArray(a)
        GL.glDisableVertexAttribArray(t)
        GL.glDepthMask(true)
        GL.glEnable(GL.GL_DEPTH_TEST)
    }

    private fun accumulate(frame: Frame) {
        frame.acquireRawDepthImage16Bits().use { depth ->
            if (depth.timestamp == lastDepth) return
            frame.acquireRawDepthConfidenceImage().use { confidence ->
                lastDepth = depth.timestamp
                val intrinsics = frame.camera.textureIntrinsics
                val resolution = intrinsics.imageDimensions
                val focal = intrinsics.focalLength
                val principal = intrinsics.principalPoint
                val sx = depth.width.toFloat() / resolution[0]
                val sy = depth.height.toFloat() / resolution[1]
                val fx = focal[0] * sx
                val fy = focal[1] * sy
                val cx = principal[0] * sx
                val cy = principal[1] * sy
                val d = depth.planes[0]
                val c = confidence.planes[0]
                val db = d.buffer.order(ByteOrder.LITTLE_ENDIAN)
                val cb = c.buffer
                for (y in 0 until depth.height step 2) for (x in 0 until depth.width step 2) {
                    if ((cb.get(y * c.rowStride + x * c.pixelStride).toInt() and 255) < 160)
                        continue
                    val metres =
                        (db.getShort(y * d.rowStride + x * d.pixelStride).toInt() and 65535) / 1000f
                    if (metres !in .2f..8f) continue
                    val p =
                        frame.camera.pose.transformPoint(
                            floatArrayOf((x - cx) * metres / fx, -(y - cy) * metres / fy, -metres)
                        )
                    val cells = p.map { floor(it / voxel).toLong() + 1048576L }
                    if (cells.any { it !in 0L..2097151L }) continue
                    val key = (cells[0] shl 42) or (cells[1] shl 21) or cells[2]
                    if (occupied.contains(key)) continue
                    if (total >= 2_000_000) {
                        flush()
                        fail("Capture limit reached — finish this segment")
                        return
                    }
                    occupied.add(key)
                    for (k in 0..2) {
                        points[total * 3 + k] = p[k]
                        pending[pendingCount * 3 + k] = p[k]
                    }
                    total++
                    pendingCount++
                    previewDirty = true
                    if (pendingCount >= pending.size / 3) flush()
                }
                if (retainRaw && rawBytes < 1024L * 1024 * 1024) {
                    val dir = directory ?: return
                    val name = "depth-${depth.timestamp}"
                    val bytes =
                        ByteBuffer.allocate(depth.width * depth.height * 2)
                            .order(ByteOrder.LITTLE_ENDIAN)
                    val confidences = ByteArray(depth.width * depth.height)
                    for (y in 0 until depth.height) for (x in 0 until depth.width) {
                        bytes.putShort(db.getShort(y * d.rowStride + x * d.pixelStride))
                        confidences[y * depth.width + x] =
                            cb.get(y * c.rowStride + x * c.pixelStride)
                    }
                    writeAtomic(File(dir, "$name.bin"), bytes.array())
                    writeAtomic(File(dir, "$name-confidence.bin"), confidences)
                    val pose = FloatArray(16)
                    frame.camera.pose.toMatrix(pose, 0)
                    val meta =
                        JSONObject()
                            .put("encoding", "uint16-little-endian-millimetres")
                            .put("width", depth.width)
                            .put("height", depth.height)
                            .put("confidenceEncoding", "uint8 0..255")
                            .put("timestamp", depth.timestamp)
                            .put("cameraToWorldColumnMajor", JSONArray(pose.toList()))
                            .put(
                                "intrinsics",
                                JSONObject().put("fx", fx).put("fy", fy).put("cx", cx).put("cy", cy),
                            )
                    writeAtomic(File(dir, "$name.json"), meta.toString().toByteArray())
                    rawBytes += bytes.capacity() + confidences.size
                }
            }
        }
    }

    private fun flush() {
        val dir = directory ?: return
        if (pendingCount == 0) return
        check(dir.usableSpace > 256L * 1024 * 1024) { "Storage is low — finish this capture" }
        writePointChunk(
            File(dir, "part-${(++chunk).toString().padStart(6,'0')}.ply"),
            pending,
            pendingCount,
        )
        pendingCount = 0
    }

    private fun writeQuality() {
        val dir = directory ?: return
        val metadata =
            JSONObject()
                .put("source", "ARCore estimated depth; may include hardware ToF")
                .put("voxelMetres", voxel)
                .put("minimumConfidence", 160)
                .put("trackingLossEvents", trackingLosses)
                .put("segments", segments)
                .put("points", total)
                .put("rawDepthBytes", rawBytes)
                .put(
                    "accuracy",
                    "Uncalibrated pose-based depth accumulation; no loop-closure optimization",
                )
        writeAtomic(File(dir, "capture.json"), metadata.toString().toByteArray())
    }

    private fun status(guidance: String) {
        emit(
            mapOf(
                "points" to total,
                "triangles" to 0,
                "memoryBytes" to total * 12 + occupied.size * 40,
                "guidance" to guidance,
                "tracking" to lastTracking,
                "paused" to !capturing,
            )
        )
    }

    private fun fail(message: String) {
        capturing = false
        status(message)
    }
}
