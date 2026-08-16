package com.jy.cadenza.android

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject

data class SavedLocalPlaylist(
    val tracks: List<LocalTrack>,
    val currentIndex: Int,
)

class LocalPlaylistStore(
    context: Context,
    preferencesName: String = PREFERENCES_NAME,
) {
    private val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)

    fun load(): SavedLocalPlaylist? = runCatching {
        val encoded = preferences.getString(PLAYLIST_KEY, null) ?: return null
        val array = JSONArray(encoded)
        val tracks = buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                val uri = item.optString("uri").takeIf(String::isNotBlank) ?: continue
                val name = item.optString("name").takeIf(String::isNotBlank)
                    ?: Uri.parse(uri).lastPathSegment
                    ?: "선택한 음악"
                add(LocalTrack(Uri.parse(uri), name))
            }
        }
        if (tracks.isEmpty()) return null
        SavedLocalPlaylist(
            tracks = tracks,
            currentIndex = preferences.getInt(INDEX_KEY, 0).coerceIn(tracks.indices),
        )
    }.getOrNull()

    fun save(tracks: List<LocalTrack>, currentIndex: Int) {
        if (tracks.isEmpty()) {
            clear()
            return
        }
        val array = JSONArray().apply {
            tracks.forEach { track ->
                put(
                    JSONObject()
                        .put("uri", track.uri.toString())
                        .put("name", track.name),
                )
            }
        }
        preferences.edit()
            .putString(PLAYLIST_KEY, array.toString())
            .putInt(INDEX_KEY, currentIndex.coerceIn(tracks.indices))
            .apply()
    }

    fun clear() {
        preferences.edit().remove(PLAYLIST_KEY).remove(INDEX_KEY).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "cadenza_local_playlist"
        const val PLAYLIST_KEY = "playlist.v1"
        const val INDEX_KEY = "current_index"
    }
}
