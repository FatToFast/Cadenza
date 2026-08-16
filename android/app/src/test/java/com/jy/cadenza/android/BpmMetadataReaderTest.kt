package com.jy.cadenza.android

import java.io.ByteArrayInputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BpmMetadataReaderTest {
    @Test
    fun readsUtf8TbpmFromId3v24() {
        val payload = byteArrayOf(3) + "128.5".toByteArray()
        val frame = "TBPM".toByteArray() + synchsafe(payload.size) + byteArrayOf(0, 0) + payload
        val tag = "ID3".toByteArray() + byteArrayOf(4, 0, 0) + synchsafe(frame.size) + frame

        assertEquals(128.5f, BpmMetadataReader.readId3Bpm(ByteArrayInputStream(tag)))
    }

    @Test
    fun ignoresFilesWithoutId3Header() {
        assertNull(BpmMetadataReader.readId3Bpm(ByteArrayInputStream("not an mp3 tag".toByteArray())))
    }

    private fun synchsafe(value: Int): ByteArray = byteArrayOf(
        ((value shr 21) and 0x7f).toByte(),
        ((value shr 14) and 0x7f).toByte(),
        ((value shr 7) and 0x7f).toByte(),
        (value and 0x7f).toByte(),
    )
}
