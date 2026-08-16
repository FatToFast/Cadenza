package com.jy.cadenza.android

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BpmStoreDeviceTest {
    @Test
    fun persistsValueAndInvalidatesItWhenFileChanges() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.cacheDir, "bpm-store-test.mp3")
        file.writeBytes(byteArrayOf(1, 2, 3))
        val track = LocalTrack(Uri.fromFile(file), file.name)
        val store = BpmStore(context)

        try {
            store.put(track, 128f, BpmStatus.DETECTED)
            assertEquals(SavedBpm(128f, BpmStatus.DETECTED), store.get(track))

            file.appendBytes(byteArrayOf(4))
            assertNull(store.get(track))
        } finally {
            store.remove(track)
            file.delete()
        }
    }
}
