package com.jy.cadenza.android

import android.content.Context
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalPlaylistStoreDeviceTest {
    @Test
    fun roundTripAndClearPreservePlaylistState() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val preferencesName = "cadenza_local_playlist_test"
        val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
        preferences.edit().clear().commit()
        val store = LocalPlaylistStore(context, preferencesName)
        val tracks = listOf(
            LocalTrack(Uri.parse("content://music/first"), "First.mp3"),
            LocalTrack(Uri.parse("content://music/second"), "Second.mp3"),
        )

        try {
            store.save(tracks, currentIndex = 1)
            assertEquals(SavedLocalPlaylist(tracks, 1), store.load())

            store.clear()
            assertNull(store.load())
        } finally {
            store.clear()
        }
    }
}
