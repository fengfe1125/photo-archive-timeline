package com.photoarchive.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photoarchive.app.data.model.MediaItem
import com.photoarchive.app.data.model.MediaSection
import com.photoarchive.app.data.repository.MediaRepository
import com.photoarchive.app.domain.usecase.GroupMedia
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

data class LibraryUiState(
    val loading: Boolean = true,
    val permissionGranted: Boolean = false,
    val sections: List<MediaSection> = emptyList(),
    val totalCount: Int = 0,
    val error: String? = null
)

/** 照片网格库，对应 iOS Features/LibraryView.swift。 */
class LibraryViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = MediaRepository(application)

    private val _uiState = MutableStateFlow(LibraryUiState())
    val uiState: StateFlow<LibraryUiState> = _uiState.asStateFlow()

    private var started = false

    /** 权限通过后调用，开始观察相册。 */
    fun onPermissionGranted() {
        _uiState.value = _uiState.value.copy(permissionGranted = true)
        if (started) return
        started = true
        viewModelScope.launch {
            repository.observeMedia()
                .catch { e ->
                    _uiState.value = _uiState.value.copy(
                        loading = false,
                        error = e.message ?: "读取本机相册失败。"
                    )
                }
                .collect { items -> publish(items) }
        }
    }

    fun onPermissionDenied() {
        _uiState.value = _uiState.value.copy(
            loading = false,
            permissionGranted = false,
            sections = emptyList()
        )
    }

    private fun publish(items: List<MediaItem>) {
        _uiState.value = LibraryUiState(
            loading = false,
            permissionGranted = true,
            sections = GroupMedia.byDay(items),
            totalCount = items.size,
            error = null
        )
    }
}
