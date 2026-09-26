package com.photoarchive.app.data.repository

import android.content.Context
import android.net.Uri
import com.photoarchive.app.data.model.MediaItem
import com.photoarchive.app.data.model.UploadState
import com.photoarchive.app.data.remote.SupabaseProvider
import io.github.jan.supabase.storage.storage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlin.time.Duration.Companion.minutes

/**
 * 将本地原片上传到 Supabase Storage，对应 iOS 端 Services/CloudMediaUploader.swift。
 *
 * 与 iOS 一致的约束：
 * - 对象路径为 "<userId>/<mediaId>"，便于 RLS 按用户隔离；
 * - 超过 50 MB 的原片不上传（iOS 也是这个上限）。
 */
class UploadRepository(
    private val context: Context,
    private val authRepository: AuthRepository = AuthRepository()
) {

    /** 上传单项，以 Flow 形式报告进度。 */
    fun upload(item: MediaItem): Flow<UploadState> = flow {
        emit(UploadState.Preparing)

        val client = SupabaseProvider.client
        if (client == null) {
            emit(UploadState.Failed(SupabaseProvider.NOT_CONFIGURED_MESSAGE))
            return@flow
        }
        val userId = authRepository.currentUserId()
        if (userId.isNullOrBlank()) {
            emit(UploadState.Failed("请先登录账户再上传原片。"))
            return@flow
        }

        val bytes = runCatching { readBytes(Uri.parse(item.uri)) }.getOrNull()
        if (bytes == null || bytes.isEmpty()) {
            emit(UploadState.Failed("这张照片在本机不可读取，云端原片尚未上传。"))
            return@flow
        }
        if (bytes.size > MAX_UPLOAD_BYTES) {
            emit(UploadState.Failed("原片超过当前云端 50 MB 上限，已留在设备。"))
            return@flow
        }

        val objectPath = "$userId/${item.id.replace(':', '-')}"
        emit(UploadState.Progress(bytesSent = 0L, totalBytes = bytes.size.toLong()))

        val result = runCatching {
            client.storage.from(SupabaseProvider.BUCKET_MEDIA).upload(objectPath, bytes) {
                upsert = true
            }
        }
        result.fold(
            onSuccess = {
                emit(UploadState.Progress(bytes.size.toLong(), bytes.size.toLong()))
                emit(UploadState.Success(objectPath))
            },
            onFailure = { error ->
                emit(UploadState.Failed(error.message ?: "原片上传失败，稍后可重试。"))
            }
        )
    }.flowOn(Dispatchers.IO)

    /** 批量上传，逐项报告。 */
    fun uploadAll(items: List<MediaItem>): Flow<Pair<MediaItem, UploadState>> = flow {
        items.forEach { item ->
            upload(item).collect { state -> emit(item to state) }
        }
    }.flowOn(Dispatchers.IO)

    /** 为已上传对象创建临时访问链接，对应 iOS createSignedURL。 */
    suspend fun signedUrl(objectPath: String): String? {
        val client = SupabaseProvider.client ?: return null
        return runCatching {
            client.storage.from(SupabaseProvider.BUCKET_MEDIA)
                .createSignedUrl(objectPath, expiresIn = 15.minutes)
        }.getOrNull()
    }

    private fun readBytes(uri: Uri): ByteArray? =
        context.contentResolver.openInputStream(uri)?.use { it.readBytes() }

    companion object {
        const val MAX_UPLOAD_BYTES: Int = 50 * 1024 * 1024
    }
}
