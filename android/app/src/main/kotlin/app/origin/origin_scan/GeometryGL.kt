package app.origin.origin_scan

import android.content.Context
import android.opengl.GLES30 as GL
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.os.Handler
import android.os.Looper
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.IntBuffer
import java.util.concurrent.Executors
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.*

internal data class MeshData(val positions: FloatArray, val indices: IntArray = intArrayOf())

internal fun floats(values: FloatArray): FloatBuffer =
    ByteBuffer.allocateDirect(values.size * 4)
        .order(ByteOrder.nativeOrder())
        .asFloatBuffer()
        .apply {
            put(values)
            position(0)
        }

internal fun ints(values: IntArray): IntBuffer =
    ByteBuffer.allocateDirect(values.size * 4).order(ByteOrder.nativeOrder()).asIntBuffer().apply {
        put(values)
        position(0)
    }

internal fun program(vertex: String, fragment: String): Int {
    fun shader(type: Int, source: String): Int {
        val id = GL.glCreateShader(type)
        GL.glShaderSource(id, source)
        GL.glCompileShader(id)
        val success = IntArray(1)
        GL.glGetShaderiv(id, GL.GL_COMPILE_STATUS, success, 0)
        check(success[0] != 0) { GL.glGetShaderInfoLog(id) }
        return id
    }
    val v = shader(GL.GL_VERTEX_SHADER, vertex)
    val f = shader(GL.GL_FRAGMENT_SHADER, fragment)
    val id = GL.glCreateProgram()
    GL.glAttachShader(id, v)
    GL.glAttachShader(id, f)
    GL.glLinkProgram(id)
    val ok = IntArray(1)
    GL.glGetProgramiv(id, GL.GL_LINK_STATUS, ok, 0)
    check(ok[0] != 0) { GL.glGetProgramInfoLog(id) }
    GL.glDeleteShader(v)
    GL.glDeleteShader(f)
    return id
}

internal class MeshGpu {
    private var programId = 0
    private val buffers = IntArray(4)
    private var pointCount = 0
    private var indexCount = 0
    private var lineCount = 0

    fun init() {
        programId =
            program(
                """attribute vec3 aPosition; attribute vec3 aNormal; uniform mat4 uMvp; uniform mediump float uPoints; varying mediump float light;
            void main(){ gl_Position=uMvp*vec4(aPosition,1.0); gl_PointSize=3.0; light=uPoints>0.5 ? 0.85 : 0.35+0.65*abs(dot(normalize(aNormal+vec3(0.0001)),normalize(vec3(0.5,0.8,1.0)))); }""",
                """precision mediump float; varying mediump float light; uniform mediump float uPoints; void main(){ if(uPoints>0.5 && length(gl_PointCoord-vec2(0.5))>0.5) discard; gl_FragColor=vec4(vec3(0.70,0.81,0.68)*light,1.0); }""",
            )
        GL.glGenBuffers(4, buffers, 0)
    }

    fun upload(mesh: MeshData) {
        pointCount = mesh.positions.size / 3
        val normals = FloatArray(mesh.positions.size)
        for (i in mesh.indices.indices step 3) {
            val a = mesh.indices[i] * 3
            val b = mesh.indices[i + 1] * 3
            val c = mesh.indices[i + 2] * 3
            val ux = mesh.positions[b] - mesh.positions[a]
            val uy = mesh.positions[b + 1] - mesh.positions[a + 1]
            val uz = mesh.positions[b + 2] - mesh.positions[a + 2]
            val vx = mesh.positions[c] - mesh.positions[a]
            val vy = mesh.positions[c + 1] - mesh.positions[a + 1]
            val vz = mesh.positions[c + 2] - mesh.positions[a + 2]
            val nx = uy * vz - uz * vy
            val ny = uz * vx - ux * vz
            val nz = ux * vy - uy * vx
            normals[a] += nx
            normals[a + 1] += ny
            normals[a + 2] += nz
            normals[b] += nx
            normals[b + 1] += ny
            normals[b + 2] += nz
            normals[c] += nx
            normals[c + 1] += ny
            normals[c + 2] += nz
        }
        // Full-resolution geometry stays on disk. Interactive triangles use bounded LOD.
        val step = max(1, (mesh.indices.size / 3 + 999999) / 1000000)
        val indices =
            if (step == 1) mesh.indices
            else
                IntArray(((mesh.indices.size / 3 + step - 1) / step) * 3).apply {
                    var at = 0
                    for (i in mesh.indices.indices step step * 3) {
                        this[at++] = mesh.indices[i]
                        this[at++] = mesh.indices[i + 1]
                        this[at++] = mesh.indices[i + 2]
                    }
                }
        val edges = IntArray(indices.size * 2)
        for (i in indices.indices step 3) {
            val j = i * 2
            edges[j] = indices[i]
            edges[j + 1] = indices[i + 1]
            edges[j + 2] = indices[i + 1]
            edges[j + 3] = indices[i + 2]
            edges[j + 4] = indices[i + 2]
            edges[j + 5] = indices[i]
        }
        indexCount = indices.size
        lineCount = edges.size
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, buffers[0])
        GL.glBufferData(
            GL.GL_ARRAY_BUFFER,
            mesh.positions.size * 4,
            floats(mesh.positions),
            GL.GL_STATIC_DRAW,
        )
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, buffers[1])
        GL.glBufferData(GL.GL_ARRAY_BUFFER, normals.size * 4, floats(normals), GL.GL_STATIC_DRAW)
        GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, buffers[2])
        GL.glBufferData(
            GL.GL_ELEMENT_ARRAY_BUFFER,
            indices.size * 4,
            ints(indices),
            GL.GL_STATIC_DRAW,
        )
        GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, buffers[3])
        GL.glBufferData(GL.GL_ELEMENT_ARRAY_BUFFER, edges.size * 4, ints(edges), GL.GL_STATIC_DRAW)
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0)
        GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, 0)
    }

    fun draw(mvp: FloatArray, mode: String) {
        if (pointCount == 0) return
        GL.glUseProgram(programId)
        GL.glUniformMatrix4fv(GL.glGetUniformLocation(programId, "uMvp"), 1, false, mvp, 0)
        val points = mode == "points" || indexCount == 0
        GL.glUniform1f(GL.glGetUniformLocation(programId, "uPoints"), if (points) 1f else 0f)
        val a = GL.glGetAttribLocation(programId, "aPosition")
        val n = GL.glGetAttribLocation(programId, "aNormal")
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, buffers[0])
        GL.glEnableVertexAttribArray(a)
        GL.glVertexAttribPointer(a, 3, GL.GL_FLOAT, false, 12, 0)
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, buffers[1])
        GL.glEnableVertexAttribArray(n)
        GL.glVertexAttribPointer(n, 3, GL.GL_FLOAT, false, 12, 0)
        if (points) GL.glDrawArrays(GL.GL_POINTS, 0, pointCount)
        else {
            GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, buffers[if (mode == "wireframe") 3 else 2])
            GL.glDrawElements(
                if (mode == "wireframe") GL.GL_LINES else GL.GL_TRIANGLES,
                if (mode == "wireframe") lineCount else indexCount,
                GL.GL_UNSIGNED_INT,
                0,
            )
        }
        GL.glDisableVertexAttribArray(a)
        GL.glDisableVertexAttribArray(n)
        GL.glBindBuffer(GL.GL_ARRAY_BUFFER, 0)
        GL.glBindBuffer(GL.GL_ELEMENT_ARRAY_BUFFER, 0)
    }
}

internal fun readCanonicalPly(file: File): MeshData {
    require(file.length() <= 256L * 1024 * 1024) { "Geometry exceeds viewer limit" }
    file.inputStream().buffered().use { stream ->
        val header = StringBuilder()
        while (!header.endsWith("end_header\n")) {
            val v = stream.read()
            require(v >= 0 && header.length < 65536) { "Invalid PLY header" }
            header.append(v.toChar())
        }
        require(header.contains("format binary_little_endian 1.0"))
        val n = Regex("element vertex (\\d+)").find(header)!!.groupValues[1].toInt()
        val triangles = Regex("element face (\\d+)").find(header)!!.groupValues[1].toInt()
        require(n in 1..5000000 && triangles in 0..10000000)
        val stride = if (header.contains("property uchar red")) 15 else 12
        val bytes = stream.readBytes()
        require(bytes.size.toLong() == n.toLong() * stride + triangles.toLong() * 13)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val positions = FloatArray(n * 3)
        val indices = IntArray(triangles * 3)
        for (i in 0 until n) {
            for (k in 0..2) {
                val v = b.float
                require(v.isFinite())
                positions[i * 3 + k] = v
            }
            if (stride == 15) b.position(b.position() + 3)
        }
        for (i in 0 until triangles) {
            require(b.get().toInt() == 3)
            for (k in 0..2) {
                val v = b.int
                require(v in 0 until n)
                indices[i * 3 + k] = v
            }
        }
        return MeshData(positions, indices)
    }
}

internal class GeometryPlatformView(context: Context, id: Int, messenger: BinaryMessenger) :
    PlatformView {
    private val channel = MethodChannel(messenger, "app.origin/viewer/$id")
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val surface = GLSurfaceView(context)
    private val renderer =
        ViewerRenderer(
            { payload -> main.post { channel.invokeMethod("measurement", payload) } },
            { error -> main.post { channel.invokeMethod("error", error) } },
        )

    init {
        surface.setEGLContextClientVersion(3)
        surface.preserveEGLContextOnPause = true
        surface.setRenderer(renderer)
        surface.renderMode = GLSurfaceView.RENDERMODE_WHEN_DIRTY
        val scale =
            ScaleGestureDetector(
                context,
                object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
                    override fun onScale(d: ScaleGestureDetector): Boolean {
                        renderer.distance = (renderer.distance / d.scaleFactor).coerceIn(.05f, 100f)
                        surface.requestRender()
                        return true
                    }
                },
            )
        val tap =
            GestureDetector(
                context,
                object : GestureDetector.SimpleOnGestureListener() {
                    override fun onDown(e: MotionEvent) = true

                    override fun onSingleTapUp(e: MotionEvent): Boolean {
                        if (renderer.measuring) {
                            surface.queueEvent {
                                renderer.pick(e.x, e.y)
                                surface.requestRender()
                            }
                        }
                        return true
                    }
                },
            )
        var x = 0f
        var y = 0f
        surface.setOnTouchListener { _, e ->
            scale.onTouchEvent(e)
            tap.onTouchEvent(e)
            val cx =
                (0 until e.pointerCount).sumOf { e.getX(it).toDouble() }.toFloat() / e.pointerCount
            val cy =
                (0 until e.pointerCount).sumOf { e.getY(it).toDouble() }.toFloat() / e.pointerCount
            if (e.actionMasked == MotionEvent.ACTION_MOVE && !scale.isInProgress) {
                if (e.pointerCount == 1 && !renderer.measuring) {
                    renderer.yaw += (cx - x) * .008f
                    renderer.pitch = (renderer.pitch + (cy - y) * .008f).coerceIn(-1.55f, 1.55f)
                    renderer.orthographic = false
                } else if (e.pointerCount >= 2) {
                    val factor = renderer.radius * renderer.distance / max(surface.height, 1)
                    renderer.panX -= (cx - x) * factor
                    renderer.panY += (cy - y) * factor
                }
                surface.requestRender()
            }
            x = cx
            y = cy
            true
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "load" ->
                    worker.execute {
                        try {
                            val data = readCanonicalPly(File(call.argument<String>("path")!!))
                            surface.queueEvent {
                                renderer.setData(data)
                                renderer.mode = call.argument<String>("mode") ?: "points"
                                surface.requestRender()
                                main.post { result.success(null) }
                            }
                        } catch (e: Exception) {
                            main.post { result.error("geometry", e.message, null) }
                        }
                    }
                "view" -> {
                    surface.queueEvent {
                        renderer.setView(call.argument<String>("view") ?: "perspective")
                        surface.requestRender()
                    }
                    result.success(null)
                }
                "mode" -> {
                    renderer.mode = call.argument<String>("mode") ?: "points"
                    surface.requestRender()
                    result.success(null)
                }
                "measure" -> {
                    renderer.measuring = call.argument<Boolean>("enabled") ?: false
                    surface.queueEvent {
                        renderer.clearMeasurement()
                        surface.requestRender()
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun getView(): View = surface

    override fun dispose() {
        channel.setMethodCallHandler(null)
        surface.onPause()
        worker.shutdownNow()
    }
}

internal class ViewerRenderer(
    private val measurement: (Map<String, Any>) -> Unit,
    private val reportError: (String) -> Unit,
) : GLSurfaceView.Renderer {
    private val gpu = MeshGpu()
    private var data: MeshData? = null
    var mode = "points"
    var measuring = false
    var radius = 1f
    var distance = 3.2f
    var yaw = .78f
    var pitch = .4f
    var panX = 0f
    var panY = 0f
    var orthographic = false
    private var width = 1
    private var height = 1
    private val center = FloatArray(3)
    private val mvp = FloatArray(16)
    private var first: FloatArray? = null
    private var ready = false

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        try {
            gpu.init()
            data?.let { gpu.upload(it) }
            GL.glClearColor(32 / 255f, 38 / 255f, 36 / 255f, 1f)
            GL.glEnable(GL.GL_DEPTH_TEST)
            ready = true
        } catch (e: Exception) {
            ready = false
            reportError("This device could not initialize 3D rendering: ${e.message}")
        }
    }

    override fun onSurfaceChanged(gl: GL10?, w: Int, h: Int) {
        width = w
        height = h
        GL.glViewport(0, 0, w, h)
    }

    override fun onDrawFrame(gl: GL10?) {
        GL.glClear(GL.GL_COLOR_BUFFER_BIT or GL.GL_DEPTH_BUFFER_BIT)
        if (!ready) return
        val target =
            floatArrayOf(
                center[0] + cos(yaw) * panX - sin(yaw) * sin(pitch) * panY,
                center[1] + cos(pitch) * panY,
                center[2] - sin(yaw) * panX - cos(yaw) * sin(pitch) * panY,
            )
        val d = radius * distance
        val eye =
            floatArrayOf(
                target[0] + sin(yaw) * cos(pitch) * d,
                target[1] + sin(pitch) * d,
                target[2] + cos(yaw) * cos(pitch) * d,
            )
        val view = FloatArray(16)
        val proj = FloatArray(16)
        Matrix.setLookAtM(
            view,
            0,
            eye[0],
            eye[1],
            eye[2],
            target[0],
            target[1],
            target[2],
            0f,
            1f,
            0f,
        )
        val aspect = width.toFloat() / max(height, 1)
        if (orthographic) {
            val s = radius * distance * .45f
            Matrix.orthoM(proj, 0, -s * aspect, s * aspect, -s, s, radius * .0001f, radius * 200)
        } else Matrix.perspectiveM(proj, 0, 50f, aspect, radius * .0001f, radius * 200)
        Matrix.multiplyMM(mvp, 0, proj, 0, view, 0)
        gpu.draw(mvp, mode)
    }

    fun setData(mesh: MeshData) {
        data = mesh
        if (ready) gpu.upload(mesh)
        val lo = floatArrayOf(Float.MAX_VALUE, Float.MAX_VALUE, Float.MAX_VALUE)
        val hi = floatArrayOf(-Float.MAX_VALUE, -Float.MAX_VALUE, -Float.MAX_VALUE)
        for (i in mesh.positions.indices step 3) for (k in 0..2) {
            lo[k] = min(lo[k], mesh.positions[i + k])
            hi[k] = max(hi[k], mesh.positions[i + k])
        }
        for (k in 0..2) center[k] = (lo[k] + hi[k]) / 2
        radius =
            max(
                .01f,
                sqrt((0..2).sumOf { ((hi[it] - lo[it]) * (hi[it] - lo[it])).toDouble() })
                    .toFloat() / 2,
            )
        setView("perspective")
    }

    fun setView(view: String) {
        distance = 3.2f
        panX = 0f
        panY = 0f
        orthographic = view != "perspective"
        when (view) {
            "top" -> {
                yaw = 0f
                pitch = 1.569f
            }
            "front" -> {
                yaw = 0f
                pitch = 0f
            }
            "side" -> {
                yaw = 1.5708f
                pitch = 0f
            }
            else -> {
                yaw = .78f
                pitch = .4f
            }
        }
    }

    fun clearMeasurement() {
        first = null
    }

    fun pick(x: Float, y: Float) {
        val mesh = data ?: return
        var selected: FloatArray? = null
        var closest = 32f * 32f
        var depth = 1f
        val out = FloatArray(4)
        val step = max(1, mesh.positions.size / 3 / 500000)
        for (i in 0 until mesh.positions.size / 3 step step) {
            val p =
                floatArrayOf(
                    mesh.positions[i * 3],
                    mesh.positions[i * 3 + 1],
                    mesh.positions[i * 3 + 2],
                    1f,
                )
            Matrix.multiplyMV(out, 0, mvp, 0, p, 0)
            if (out[3] <= 0) continue
            val z = out[2] / out[3]
            if (z !in -1f..1f) continue
            val sx = (out[0] / out[3] * .5f + .5f) * width
            val sy = (.5f - out[1] / out[3] * .5f) * height
            val d = (sx - x) * (sx - x) + (sy - y) * (sy - y)
            if (d < closest || (abs(d - closest) < 4 && z < depth)) {
                closest = d
                depth = z
                selected = p.copyOf(3)
            }
        }
        val p = selected ?: return
        val a = first
        if (a == null) {
            first = p
            measurement(mapOf("from" to p.toList()))
        } else {
            val distance = sqrt((0..2).sumOf { ((a[it] - p[it]) * (a[it] - p[it])).toDouble() })
            measurement(mapOf("from" to a.toList(), "to" to p.toList(), "distance" to distance))
            first = null
        }
    }
}
