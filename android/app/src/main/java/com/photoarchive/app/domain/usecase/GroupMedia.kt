package com.photoarchive.app.domain.usecase

import com.photoarchive.app.data.model.MediaItem
import com.photoarchive.app.data.model.MediaSection
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 时间线分组逻辑，对应 iOS 端 ArchiveDay / StoriesView 的分组方式。
 */
object GroupMedia {

    enum class Granularity { DAY, MONTH, YEAR }

    fun byDay(items: List<MediaItem>): List<MediaSection> = group(items, Granularity.DAY)

    fun byMonth(items: List<MediaItem>): List<MediaSection> = group(items, Granularity.MONTH)

    fun group(items: List<MediaItem>, granularity: Granularity): List<MediaSection> {
        val keyFormat = when (granularity) {
            Granularity.DAY -> "yyyy-MM-dd"
            Granularity.MONTH -> "yyyy-MM"
            Granularity.YEAR -> "yyyy"
        }
        val labelFormat = when (granularity) {
            Granularity.DAY -> "yyyy 年 M 月 d 日"
            Granularity.MONTH -> "yyyy 年 M 月"
            Granularity.YEAR -> "yyyy 年"
        }
        val keyFormatter = SimpleDateFormat(keyFormat, Locale.getDefault())
        val labelFormatter = SimpleDateFormat(labelFormat, Locale.getDefault())

        return items
            .sortedByDescending { it.dateTaken }
            .groupBy { item ->
                if (item.dateTaken <= 0L) "unknown" else keyFormatter.format(Date(item.dateTaken))
            }
            .map { (key, groupItems) ->
                val label = if (key == "unknown") {
                    "时间未知"
                } else {
                    labelFormatter.format(Date(groupItems.first().dateTaken))
                }
                MediaSection(key = key, label = label, items = groupItems)
            }
    }
}
