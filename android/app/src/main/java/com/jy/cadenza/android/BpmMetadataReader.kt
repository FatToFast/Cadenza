package com.jy.cadenza.android

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.InputStream
import java.nio.charset.Charset

object BpmMetadataReader {
    private const val MAX_TAG_BYTES = 2 * 1024 * 1024

    suspend fun read(context: Context, uri: Uri): Float? = withContext(Dispatchers.IO) {
        runCatching {
            context.contentResolver.openInputStream(uri)?.buffered()?.use(::readId3Bpm)
        }.getOrNull()
    }

    internal fun readId3Bpm(input: InputStream): Float? {
        val header = input.readExact(10) ?: return null
        if (!header.copyOfRange(0, 3).contentEquals("ID3".toByteArray())) return null
        val version = header[3].toInt() and 0xff
        if (version !in 2..4) return null
        val tagSize = synchsafeInt(header, 6)
        if (tagSize <= 0 || tagSize > MAX_TAG_BYTES) return null
        val tag = input.readExact(tagSize) ?: return null
        return if (version == 2) readV22(tag) else readV23OrV24(tag, version)
    }

    private fun readV23OrV24(tag: ByteArray, version: Int): Float? {
        if (tag.size < 10) return null
        for (offset in 0..tag.size - 10) {
            if (!tag.matchesAscii(offset, "TBPM")) continue
            val frameSize = if (version == 4) synchsafeInt(tag, offset + 4) else bigEndianInt(tag, offset + 4)
            if (frameSize <= 1 || offset + 10 + frameSize > tag.size) continue
            return decodeText(tag.copyOfRange(offset + 10, offset + 10 + frameSize))
        }
        return null
    }

    private fun readV22(tag: ByteArray): Float? {
        if (tag.size < 6) return null
        for (offset in 0..tag.size - 6) {
            if (!tag.matchesAscii(offset, "TBP")) continue
            val frameSize = ((tag[offset + 3].toInt() and 0xff) shl 16) or
                ((tag[offset + 4].toInt() and 0xff) shl 8) or
                (tag[offset + 5].toInt() and 0xff)
            if (frameSize <= 1 || offset + 6 + frameSize > tag.size) continue
            return decodeText(tag.copyOfRange(offset + 6, offset + 6 + frameSize))
        }
        return null
    }

    private fun decodeText(frame: ByteArray): Float? {
        if (frame.size <= 1) return null
        val charset = when (frame[0].toInt() and 0xff) {
            1 -> Charsets.UTF_16
            2 -> Charsets.UTF_16BE
            3 -> Charsets.UTF_8
            else -> Charset.forName("ISO-8859-1")
        }
        val value = frame.copyOfRange(1, frame.size)
            .toString(charset)
            .trim('\u0000', ' ', '\t', '\r', '\n')
            .substringBefore('\u0000')
            .toFloatOrNull()
        return value?.takeIf { it.isFinite() && it in 30f..300f }
    }

    private fun InputStream.readExact(count: Int): ByteArray? {
        val result = ByteArray(count)
        var offset = 0
        while (offset < count) {
            val read = read(result, offset, count - offset)
            if (read < 0) return null
            offset += read
        }
        return result
    }

    private fun ByteArray.matchesAscii(offset: Int, value: String): Boolean =
        value.indices.all { index -> this[offset + index] == value[index].code.toByte() }

    private fun synchsafeInt(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0x7f) shl 21) or
            ((bytes[offset + 1].toInt() and 0x7f) shl 14) or
            ((bytes[offset + 2].toInt() and 0x7f) shl 7) or
            (bytes[offset + 3].toInt() and 0x7f)

    private fun bigEndianInt(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 24) or
            ((bytes[offset + 1].toInt() and 0xff) shl 16) or
            ((bytes[offset + 2].toInt() and 0xff) shl 8) or
            (bytes[offset + 3].toInt() and 0xff)
}
