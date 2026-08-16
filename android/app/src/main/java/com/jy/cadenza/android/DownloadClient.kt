package com.jy.cadenza.android

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL

data class DownloadResult(val uri: Uri, val filename: String)

class DownloadClient(private val context: Context) {
    suspend fun download(
        serverBaseUrl: String,
        videoUrl: String,
        onProgress: (String, Int?) -> Unit,
    ): DownloadResult = withContext(Dispatchers.IO) {
        val base = validatedServerUrl(serverBaseUrl)
        val created = requestJson(
            URL(base.resolve("api/download").toString()),
            "POST",
            JSONObject().put("url", videoUrl).toString(),
        )
        val id = created.getString("id")

        var filename = "cadenza-$id.mp3"
        var ready = false
        var attempts = 0
        while (!ready && attempts < 900) {
            attempts += 1
            val job = requestJson(URL(base.resolve("api/jobs/$id").toString()), "GET")
            val status = job.getString("status")
            val progress = job.optInt("progress").takeIf { job.has("progress") }
            onProgress(status, progress)
            when (status) {
                "ready" -> {
                    filename = safeFilename(job.optString("filename", filename))
                    ready = true
                }
                "failed" -> error(job.optString("error", "MP3 변환에 실패했습니다"))
            }
            if (!ready) delay(1_000)
        }

        check(ready) { "MP3 변환 시간이 초과되었습니다" }

        val connection = open(URL(base.resolve("api/jobs/$id/file").toString()), "GET")
        try {
            check(connection.responseCode in 200..299) { readError(connection) }
            val uri = saveToMusicLibrary(filename) { output ->
                connection.inputStream.use { input -> input.copyTo(output) }
            }
            DownloadResult(uri, filename)
        } finally {
            connection.disconnect()
        }
    }

    private fun validatedServerUrl(raw: String): URI {
        val normalized = if (raw.endsWith('/')) raw else "$raw/"
        val uri = URI(normalized)
        require(uri.scheme == "https") { "Tailscale HTTPS 서버 주소를 입력하세요" }
        require(!uri.host.isNullOrBlank()) { "서버 주소가 올바르지 않습니다" }
        return uri
    }

    private fun requestJson(url: URL, method: String, body: String? = null): JSONObject {
        val connection = open(url, method)
        try {
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = connection.responseCode
            check(code in 200..299) { readError(connection) }
            return JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: URL, method: String): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 30_000
            setRequestProperty("Accept", "application/json")
        }

    private fun readError(connection: HttpURLConnection): String {
        val message = connection.errorStream?.bufferedReader()?.use { it.readText() }
        return message?.takeIf { it.isNotBlank() } ?: "서버 오류 (${connection.responseCode})"
    }

    private fun safeFilename(value: String): String =
        value.substringAfterLast('/').substringAfterLast('\\').ifBlank { "cadenza.mp3" }
            .let { name -> if (name.endsWith(".mp3", ignoreCase = true)) name else "$name.mp3" }

    private fun saveToMusicLibrary(filename: String, write: (java.io.OutputStream) -> Unit): Uri {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.DISPLAY_NAME, filename)
                put(MediaStore.Audio.Media.MIME_TYPE, "audio/mpeg")
                put(MediaStore.Audio.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MUSIC}/Cadenza")
                put(MediaStore.Audio.Media.IS_PENDING, 1)
            }
            val uri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
                ?: error("음악 저장소에 MP3 파일을 만들 수 없습니다")
            try {
                resolver.openOutputStream(uri, "w")?.use(write)
                    ?: error("MP3 파일을 저장할 수 없습니다")
                resolver.update(
                    uri,
                    ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) },
                    null,
                    null,
                )
                return uri
            } catch (error: Throwable) {
                resolver.delete(uri, null, null)
                throw error
            }
        }

        val downloads = (context.getExternalFilesDir(Environment.DIRECTORY_MUSIC)
            ?: File(context.filesDir, "downloads"))
            .resolve("Cadenza")
            .apply { mkdirs() }
        val target = downloads.resolve(filename)
        target.outputStream().use(write)
        return Uri.fromFile(target)
    }
}
