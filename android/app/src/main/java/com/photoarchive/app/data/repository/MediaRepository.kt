package com.photoarchive.app.data.repository

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.photoarchive.app.data.model.MediaItem
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext

/**
 * 用 MediaStore 读取本机图片与视频，对应 iOS 端 Services/PhotoKitLibrary.swift。
 *
 * 分区存储说明：
 * - Android 13 (API 33) 及以上使用 READ_MEDIA_IMAGES / READ_MEDIA_VIDEO；
 * - Android 14 (API 34) 及以上还支持 READ_MEDIA_VISUAL_USER_SELECTED 部分授权，
 *   此时查询只会返回用户选中的那些项，无需额外处理；
 * - Android 12 (API 32) 及以下使用 READ_EXTERNAL_STORAGE。
 */
class MediaRepository(private val context: Context) {

    /** 监听相册变化并自动重新发出列表，对应 iOS 的 PHPhotoLibraryChangeObserver。 */
    fun observeMedia(): Flow<List<MediaItem>> = callbackFlow {
        val resolver = context.contentResolver

        suspend fun emitCurrent() {
            runCatching { queryAll() }
                .onSuccess { trySend(it) }
                .onFailure { trySend(emptyList()) }
        }

        val observer = object : ContentObserver(null) {
            override fun onChange(selfChange: Boolean) {
                trySend(runCatching { queryAllBlocking() }.getOrDefault(emptyList()))
            }
        }
        resolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, observer)
        resolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, observer)

        emitCurrent()
        awaitClose { resolver.unregisterContentObserver(observer) }
    }.flowOn(Dispatchers.IO)

    /** 一次性全量读取，按拍摄时间倒序。 */
    suspend fun queryAll(): List<MediaItem> = withContext(Dispatchers.IO) { queryAllBlocking() }

    private fun queryAllBlocking(): List<MediaItem> {
        val images = query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, isVideo = false)
        val videos = query(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, isVideo = true)
        return (images + videos).sortedByDescending { it.dateTaken }
    }

    /** 根据 id 取单项，给详情页使用。 */
    suspend fun findById(id: String): MediaItem? = withContext(Dispatchers.IO) {
        queryAllBlocking().firstOrNull { it.id == id }
    }

    private fun query(collection: Uri, isVideo: Boolean): List<MediaItem> {
        val projection = buildList {
            add(MediaStore.MediaColumns._ID)
            add(MediaStore.MediaColumns.DISPLAY_NAME)
            add(MediaStore.MediaColumns.MIME_TYPE)
            add(MediaStore.MediaColumns.DATE_TAKEN)
            add(MediaStore.MediaColumns.DATE_ADDED)
            add(MediaStore.MediaColumns.WIDTH)
            add(MediaStore.MediaColumns.HEIGHT)
            add(MediaStore.MediaColumns.SIZE)
            if (isVideo) add(MediaStore.Video.VideoColumns.DURATION)
            // 精确经纬度在 Android 10+ 已从 MediaStore 移除（位置脉络），
            // 仅在 Android 9 及以下可直接读取。
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                add(MediaStore.Images.ImageColumns.LATITUDE)
                add(MediaStore.Images.ImageColumns.LONGITUDE)
            }
        }.toTypedArray()

        val sortOrder = "${MediaStore.MediaColumns.DATE_TAKEN} DESC, ${MediaStore.MediaColumns.DATE_ADDED} DESC"
        val result = mutableListOf<MediaItem>()

        context.contentResolver.query(collection, projection, null, null, sortOrder)?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val mimeCol = cursor.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)
            val takenCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
            val addedCol = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
            val widthCol = cursor.getColumnIndex(MediaStore.MediaColumns.WIDTH)
            val heightCol = cursor.getColumnIndex(MediaStore.MediaColumns.HEIGHT)
            val sizeCol = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val durationCol = if (isVideo) cursor.getColumnIndex(MediaStore.Video.VideoColumns.DURATION) else -1
            val latCol = cursor.getColumnIndex(MediaStore.Images.ImageColumns.LATITUDE)
            val lonCol = cursor.getColumnIndex(MediaStore.Images.ImageColumns.LONGITUDE)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val uri = ContentUris.withAppendedId(collection, id)

                // DATE_TAKEN 单位是毫秒，DATE_ADDED 是秒；前者可能为空。
                val takenMs = if (takenCol >= 0 && !cursor.isNull(takenCol)) cursor.getLong(takenCol) else 0L
                val addedMs = if (addedCol >= 0 && !cursor.isNull(addedCol)) cursor.getLong(addedCol) * 1000L else 0L
                val dateTaken = if (takenMs > 0L) takenMs else addedMs

                val lat = if (latCol >= 0 && !cursor.isNull(latCol)) cursor.getDouble(latCol).takeIf { it != 0.0 } else null
                val lon = if (lonCol >= 0 && !cursor.isNull(lonCol)) cursor.getDouble(lonCol).takeIf { it != 0.0 } else null

                result += MediaItem(
                    id = "${if (isVideo) "video" else "image"}:$id",
                    uri = uri.toString(),
                    mimeType = if (mimeCol >= 0) cursor.getString(mimeCol) ?: fallbackMime(isVideo) else fallbackMime(isVideo),
                    dateTaken = dateTaken,
                    latitude = lat,
                    longitude = lon,
                    width = if (widthCol >= 0) cursor.getInt(widthCol) else 0,
                    height = if (heightCol >= 0) cursor.getInt(heightCol) else 0,
                    duration = if (durationCol >= 0 && !cursor.isNull(durationCol)) cursor.getLong(durationCol) else null,
                    displayName = if (nameCol >= 0) cursor.getString(nameCol) ?: "" else "",
                    sizeBytes = if (sizeCol >= 0) cursor.getLong(sizeCol) else 0L
                )
            }
        }
        return result
    }

    private fun fallbackMime(isVideo: Boolean) = if (isVideo) "video/*" else "image/*"

    companion object {
        /** 当前系统版本需要的读取权限。 */
        fun requiredPermissions(): List<String> = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> listOf(
                android.Manifest.permission.READ_MEDIA_IMAGES,
                android.Manifest.permission.READ_MEDIA_VIDEO
            )
            else -> listOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }
}
