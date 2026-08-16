package com.jy.cadenza.android

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import java.io.File
import java.security.MessageDigest

data class SavedBpm(val bpm: Float, val status: BpmStatus)

class BpmStore(private val context: Context) {
    private val preferences = context.getSharedPreferences("cadenza_bpm_cache", Context.MODE_PRIVATE)

    fun get(track: LocalTrack): SavedBpm? {
        val prefix = keyPrefix(track.uri)
        if (!preferences.contains("$prefix.bpm")) return null
        val current = fingerprint(track.uri)
        if (preferences.getLong("$prefix.size", Long.MIN_VALUE) != current.size ||
            preferences.getLong("$prefix.modified", Long.MIN_VALUE) != current.modified
        ) {
            remove(track)
            return null
        }

        val bpm = preferences.getFloat("$prefix.bpm", Float.NaN)
        val status = preferences.getString("$prefix.status", null)
            ?.let { stored -> runCatching { BpmStatus.valueOf(stored) }.getOrNull() }
        if (!bpm.isFinite() || bpm <= 0f || status !in CACHEABLE_STATUSES) {
            remove(track)
            return null
        }
        return SavedBpm(bpm, requireNotNull(status))
    }

    fun put(track: LocalTrack, bpm: Float, status: BpmStatus) {
        if (!bpm.isFinite() || bpm <= 0f || status !in CACHEABLE_STATUSES) return
        val prefix = keyPrefix(track.uri)
        val fingerprint = fingerprint(track.uri)
        preferences.edit()
            .putFloat("$prefix.bpm", bpm)
            .putString("$prefix.status", status.name)
            .putLong("$prefix.size", fingerprint.size)
            .putLong("$prefix.modified", fingerprint.modified)
            .apply()
    }

    fun remove(track: LocalTrack) {
        val prefix = keyPrefix(track.uri)
        preferences.edit()
            .remove("$prefix.bpm")
            .remove("$prefix.status")
            .remove("$prefix.size")
            .remove("$prefix.modified")
            .apply()
    }

    private fun fingerprint(uri: Uri): FileFingerprint {
        if (uri.scheme == "file") {
            val file = uri.path?.let(::File)
            return FileFingerprint(
                size = file?.takeIf(File::isFile)?.length() ?: UNKNOWN,
                modified = file?.takeIf(File::isFile)?.lastModified() ?: UNKNOWN,
            )
        }

        val size = queryLong(uri, OpenableColumns.SIZE)
        val modified = queryLong(uri, DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        return FileFingerprint(size, modified)
    }

    private fun queryLong(uri: Uri, column: String): Long = runCatching {
        context.contentResolver.query(uri, arrayOf(column), null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(column)
            if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) cursor.getLong(index) else UNKNOWN
        } ?: UNKNOWN
    }.getOrDefault(UNKNOWN)

    private fun keyPrefix(uri: Uri): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray())
        return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }
    }

    private data class FileFingerprint(val size: Long, val modified: Long)

    private companion object {
        const val UNKNOWN = -1L
        val CACHEABLE_STATUSES = setOf(BpmStatus.METADATA, BpmStatus.DETECTED, BpmStatus.MANUAL)
    }
}
