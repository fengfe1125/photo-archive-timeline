package com.photoarchive.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photoarchive.app.data.model.MediaItem
import com.photoarchive.app.data.model.UploadState
import com.photoarchive.app.data.remote.SupabaseProvider
import com.photoarchive.app.data.repository.MediaRepository
import com.photoarchive.app.data.repository.UploadRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class PhotoDetailUiState(
    val loading: Boolean = true,
    val item: MediaItem? = null,
    val uploadState: UploadState = UploadState.Idle,
    val cloudConfigured: Boolean = SupabaseProvider.isConfigured,
    val error: String? = null
)

/** 单张详情 + 上传状态，对应 iOS Features/PhotoDetailView.swift。 */
class PhotoDetailViewModel(application: Application) : AndroidViewModel(application) {

    private val mediaRepository = MediaRepository(application)
    private val uploadRepository = UploadRepository(application)

    private val _uiState = MutableStateFlow(PhotoDetailUiState())
    val uiState: StateFlow<PhotoDetailUiState> = _uiState.asStateFlow()

    fun load(photoId: String) {
        viewModelScope.launch {
            val item = runCatching { mediaRepository.findById(photoId) }.getOrNull()
            _uiState.value = _uiState.value.copy(
                loading = false,
                item = item,
                error = if (item == null) "这张照片已不在本机相册中。" else null
            )
        }
    }

    /** 上传原片到云端。 */
    fun upload() {
        val item = _uiState.value.item ?: return
        viewModelScope.launch {
            uploadRepository.upload(item).collect { state ->
                _uiState.value = _uiState.value.copy(uploadState = state)
                if (state is UploadState.Success) {
                    _uiState.value = _uiState.value.copy(
                        item = item.copy(isUploaded = true, remoteUrl = state.objectPath)
                    )
                }
            }
        }
    }

    fun dismissUploadState() {
        _uiState.value = _uiState.value.copy(uploadState = UploadState.Idle)
    }
}
