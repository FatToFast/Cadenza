package com.jy.cadenza.android

import android.net.Uri
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class BpmAnalyzerDeviceTest {
    @Test
    fun detectsBpmFromRealMp3OnDevice() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val file = File(context.filesDir, "bpm-test.mp3")
        assertTrue("Device fixture is missing: ${file.absolutePath}", file.isFile)

        val bpm = BpmAnalyzer.analyze(context, Uri.fromFile(file))
        Log.i("CadenzaBpmTest", "detectedBpm=$bpm file=${file.name}")

        assertNotNull("BPM analyzer returned no result", bpm)
        assertTrue("Detected BPM was outside the supported range: $bpm", bpm!! in 60f..220f)
    }
}
