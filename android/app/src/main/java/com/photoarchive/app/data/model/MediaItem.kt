package com.photoarchive.app.data.model

/**
 * 本地相册中的一张照片或一段视频。
 * 对应 iOS 端 Domain/Models.swift 中的 MediaItem。
 */
data class MediaItem(
    val id: String,
    val uri: String,
    val mimeType: String,
    val dateTaken: Long,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val width: Int = 0,
    val height: Int = 0,
    val duration: Long? = null, // 视频时长 ms
    val isUploaded: Boolean = false,
    val remoteUrl: String? = null,
    val displayName: String = "",
    val sizeBytes: Long = 0L
) {
    val isVideo: Boolean get() = mimeType.startsWith("video")
    val hasLocation: Boolean get() = latitude != null && longitude != null
}

/** 按日期分组后的一组媒体，用于图库时间线的 sticky header。 */
data class MediaSection(
    val key: String,
    val label: String,
    val items: List<MediaItem>
)

/** 上传进度状态，对应 iOS CloudMediaUploader 的上传生命周期。 */
sealed interface UploadState {
    data object Idle : UploadState
    data object Preparing : UploadState
    data class Progress(val bytesSent: Long, val totalBytes: Long) : UploadState {
        val fraction: Float
            get() = if (totalBytes <= 0L) 0f else (bytesSent.toFloat() / totalBytes.toFloat()).coerceIn(0f, 1f)
    }
    data class Success(val objectPath: String) : UploadState
    data class Failed(val message: String) : UploadState
}

/** 账户登录状态，对应 iOS SupabaseAccount。 */
sealed interface AccountState {
    data object NotConfigured : AccountState
    data object SignedOut : AccountState
    data class SignedIn(val userId: String, val email: String?) : AccountState
}
