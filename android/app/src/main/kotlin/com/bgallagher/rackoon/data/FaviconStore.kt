package com.bgallagher.rackoon.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.bgallagher.rackoon.core.FaviconLinks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * Favicons of bookmarked services, fetched from the phone (so Tailscale-only addresses work when the phone is on the tailnet),
 * cached as 128 px PNGs under `favicons/` with an index, like the Mac's `FaviconStore`.
 *
 * One icon per site (its origin), found from the page's `<link rel="icon">` tags and then `/favicon.ico`. A site with no icon is
 * remembered for a day so it isn't asked again on every launch; tapping an icon fetches a fresh one at once. Only a GET with no
 * credentials or cookies is sent, so certificate errors (self-signed home servers) are tolerated for this fetch and nothing else.
 * Limits: 256 KB page, 1 MB image, 6 s per request, one fetch at a time, http(s) only (also after redirects).
 */
class FaviconStore(private val directory: File, private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)) {
    @Serializable private data class Entry(val file: String? = null, val attemptedAt: Long)

    private val json = Json { ignoreUnknownKeys = true }
    private val _images = MutableStateFlow<Map<String, ImageBitmap>>(emptyMap())
    /** Origin -> icon. Loaded from disk at start, so reading it from a composable never mutates anything. */
    val images: StateFlow<Map<String, ImageBitmap>> = _images.asStateFlow()
    private val _fetching = MutableStateFlow<Set<String>>(emptySet())
    /** Origins being fetched right now. */
    val fetching: StateFlow<Set<String>> = _fetching.asStateFlow()

    private val index = mutableMapOf<String, Entry>()
    private val queue = ArrayDeque<Pair<String, String>>()
    private var worker: Job? = null
    private val lock = Any()

    init {
        directory.mkdirs()
        runCatching {
            val file = File(directory, "index.json")
            if (file.exists()) index += json.decodeFromString<Map<String, Entry>>(file.readText())
            val loaded = index.mapNotNull { (origin, e) ->
                val f = e.file?.let { File(directory, it) }?.takeIf { it.exists() } ?: return@mapNotNull null
                BitmapFactory.decodeFile(f.path)?.let { origin to it.asImageBitmap() }
            }.toMap()
            _images.value = loaded
        }
    }

    fun origin(href: String): String? = FaviconLinks.origin(href)

    /** Fetches icons that are missing: sites never tried, and sites without an icon last tried over a day ago. */
    fun ensure(hrefs: Collection<String>) {
        val now = System.currentTimeMillis()
        for (href in hrefs) {
            val origin = FaviconLinks.origin(href) ?: continue
            synchronized(lock) {
                if (origin in _fetching.value || queue.any { it.first == origin }) return@synchronized
                index[origin]?.let { if (it.file != null || now - it.attemptedAt < RETRY_AFTER_MS) return@synchronized }
                enqueue(origin, href)
            }
        }
    }

    /** The user tapped the icon: try again now, whatever was cached. */
    fun refresh(href: String) {
        val origin = FaviconLinks.origin(href) ?: return
        synchronized(lock) { if (origin !in _fetching.value) enqueue(origin, href) }
    }

    private fun enqueue(origin: String, href: String) {
        queue.addLast(origin to href)
        _fetching.update { it + origin }
        if (worker?.isActive == true) return
        worker = scope.launch {
            // One at a time, so a long bookmark list doesn't open dozens of connections at once.
            while (true) {
                val job = synchronized(lock) { queue.removeFirstOrNull() } ?: break
                val png = runCatching { fetchIcon(job.first, job.second) }.getOrNull()
                finish(job.first, png)
            }
        }
    }

    private fun finish(origin: String, png: Bitmap?) {
        synchronized(lock) {
            if (png != null) {
                val name = fileName(origin)
                runCatching { File(directory, name).outputStream().use { png.compress(Bitmap.CompressFormat.PNG, 100, it) } }
                _images.update { it + (origin to png.asImageBitmap()) }
                index[origin] = Entry(name, System.currentTimeMillis())
            } else if (index[origin]?.file == null) {
                // Nothing found, and nothing kept from before: remember the attempt. (A failed refresh keeps the old icon.)
                index[origin] = Entry(null, System.currentTimeMillis())
            }
            runCatching {
                val tmp = File(directory, "index.json.tmp")
                tmp.writeText(json.encodeToString(index.toMap()))
                if (!tmp.renameTo(File(directory, "index.json"))) { File(directory, "index.json").delete(); tmp.renameTo(File(directory, "index.json")) }
            }
            _fetching.update { it - origin }
        }
    }

    /** The page's own icon links first, then `/favicon.ico`; the first thing that decodes as an image wins. */
    private suspend fun fetchIcon(origin: String, href: String): Bitmap? = withContext(Dispatchers.IO) {
        val tried = mutableSetOf<String>()
        val urls = mutableListOf<String>()
        get(href, PAGE_LIMIT)?.let { page ->
            val html = String(page.data, Charsets.UTF_8)
            urls += FaviconLinks.candidates(html, page.finalUrl).map { it.url }
        }
        urls += FaviconLinks.defaultIcon(origin)
        for (url in urls) {
            if (!tried.add(url)) continue
            val response = get(url, IMAGE_LIMIT) ?: continue
            render(response.data)?.let { return@withContext it }
        }
        null
    }

    private class Response(val data: ByteArray, val finalUrl: String)

    /** A GET with a size cap: 2xx only, http(s) only (a redirect to anything else is refused), at most 5 redirects, no cookies. */
    private fun get(start: String, limit: Int): Response? {
        var url = start
        repeat(6) {
            val u = runCatching { URL(url) }.getOrNull() ?: return null
            if (u.protocol != "http" && u.protocol != "https") return null
            val conn = (u.openConnection() as HttpURLConnection)
            try {
                conn.instanceFollowRedirects = false   // followed here, so every hop is checked
                conn.connectTimeout = 6000
                conn.readTimeout = 6000
                conn.useCaches = false
                conn.setRequestProperty("User-Agent", "Rackoon/1.0 (favicon fetch)")
                conn.setRequestProperty("Accept", "text/html,image/*;q=0.9,*/*;q=0.5")
                if (conn is HttpsURLConnection) { conn.sslSocketFactory = trustAll.socketFactory; conn.hostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true } }
                val code = conn.responseCode
                if (code in 300..399) {
                    val location = conn.getHeaderField("Location") ?: return null
                    url = runCatching { URL(u, location).toString() }.getOrNull() ?: return null
                    return@repeat
                }
                if (code !in 200..299) return null
                val out = ByteArrayOutputStream()
                val buf = ByteArray(8192)
                conn.inputStream.use { input ->
                    while (out.size() < limit) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                    }
                }
                return if (out.size() == 0) null else Response(out.toByteArray(), url)
            } catch (_: Exception) {
                return null
            } finally {
                conn.disconnect()
            }
        }
        return null
    }

    /** Decodes whatever image format arrived (PNG, ICO, JPEG, GIF, WebP) and re-draws it centred in a 128 px square. */
    private fun render(data: ByteArray): Bitmap? {
        val src = BitmapFactory.decodeByteArray(data, 0, data.size) ?: return null
        if (src.width < 1 || src.height < 1) return null
        val side = 128
        val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val scale = minOf(side.toFloat() / src.width, side.toFloat() / src.height)
        val w = src.width * scale
        val h = src.height * scale
        Canvas(out).drawBitmap(src, null, RectF((side - w) / 2, (side - h) / 2, (side + w) / 2, (side + h) / 2), Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG))
        return out
    }

    private fun fileName(origin: String): String =
        MessageDigest.getInstance("SHA-256").digest(origin.toByteArray()).take(10).joinToString("") { "%02x".format(it) } + ".png"

    private companion object {
        const val RETRY_AFTER_MS = 24L * 3600 * 1000
        const val PAGE_LIMIT = 256 * 1024
        const val IMAGE_LIMIT = 1024 * 1024

        /** Accepts any server certificate, for the favicon GET only: no credentials or cookies are sent. */
        val trustAll: SSLContext by lazy {
            SSLContext.getInstance("TLS").apply {
                init(null, arrayOf<TrustManager>(object : X509TrustManager {
                    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {}
                    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {}
                    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
                }), SecureRandom())
            }
        }
    }
}
