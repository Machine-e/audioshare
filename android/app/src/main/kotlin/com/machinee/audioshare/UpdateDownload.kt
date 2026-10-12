package com.machinee.audioshare

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

// Report byte counts, not an estimated timer. Unknown lengths stay indeterminate.
internal fun copyUpdate(
    input: InputStream,
    output: OutputStream,
    total: Long,
    cancelled: () -> Boolean = { false },
    clock: () -> Long = { System.nanoTime() / 1_000_000 },
    progress: (Long, Long) -> Unit,
): Long {
    val buffer = ByteArray(64 * 1024)
    var received = 0L
    var lastReport = clock()
    progress(0, total)
    while (true) {
        if (cancelled()) throw IOException("下载已取消")
        val count = input.read(buffer)
        if (count < 0) break
        output.write(buffer, 0, count)
        received += count
        val now = clock()
        if (now - lastReport >= 100) {
            progress(received, total)
            lastReport = now
        }
    }
    if (cancelled()) throw IOException("下载已取消")
    if (received == 0L || (total > 0 && received != total))
        throw IOException("安装包下载不完整，请重试")
    progress(received, total)
    return received
}
