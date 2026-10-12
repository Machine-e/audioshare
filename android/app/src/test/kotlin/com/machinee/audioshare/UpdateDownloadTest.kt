package com.machinee.audioshare

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class UpdateDownloadTest {
    @Test fun reportsRealByteCountsAndThrottlesIntermediateEvents() {
        val data = ByteArray(1024 * 1024) { (it % 251).toByte() }
        val output = ByteArrayOutputStream()
        val events = mutableListOf<Pair<Long, Long>>()
        var now = 0L
        val count = copyUpdate(ByteArrayInputStream(data), output, data.size.toLong(),
            clock = { now += 20; now }) { read, total -> events.add(read to total) }
        assertArrayEquals(data, output.toByteArray())
        assertEquals(data.size.toLong(), count)
        assertEquals(0L to count, events.first())
        assertEquals(count to count, events.last())
        assertTrue(events.size in 3..6)
        assertTrue(events.zipWithNext().all { (a, b) -> a.first <= b.first })
    }

    @Test fun unknownLengthReportsBytesWithoutInventingATotal() {
        val events = mutableListOf<Pair<Long, Long>>()
        copyUpdate(ByteArrayInputStream(ByteArray(321)), ByteArrayOutputStream(), 0) {
            read, total -> events.add(read to total)
        }
        assertEquals(321L to 0L, events.last())
    }

    @Test fun truncatedAndEmptyDownloadsCannotProceedToInstaller() {
        for (data in listOf(ByteArray(0), ByteArray(30))) {
            try {
                copyUpdate(ByteArrayInputStream(data), ByteArrayOutputStream(), 50) { _, _ -> }
                fail("Incomplete APK accepted")
            } catch (_: IOException) { }
        }
    }

    @Test fun destroyedActivityCancelsBeforeWriting() {
        val output = ByteArrayOutputStream()
        try {
            copyUpdate(ByteArrayInputStream(ByteArray(20)), output, 20,
                cancelled = { true }) { _, _ -> }
            fail("Cancelled copy accepted")
        } catch (_: IOException) { }
        assertEquals(0, output.size())
    }
}
