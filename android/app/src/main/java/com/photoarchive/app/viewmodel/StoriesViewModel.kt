package com.photoarchive.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photoarchive.app.data.model.MediaSection
import com.photoarchive.app.data.repository.MediaRepository
import com.photoarchive.app.domain.usecase.GroupMedia
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.launch

data class StoriesUiState(
    val loading: Boolean = true,
    val granularity: GroupMedia.Granularity = GroupMedia.Granularity.MONTH,
    val sections: List<MediaSection> = emptyList(),
    val error: String? = null
)

/** 按月/年的时间线故事，对应 iOS Features/StoriesView.swift。 */
class StoriesViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = MediaRepository(application)

    private val _uiState = MutableStateFlow(StoriesUiState())
    val uiState: StateFlow<StoriesUiState> = _uiState.asStateFlow()

    private var started = false

    fun start() {
        if (started) return
        started = true
        viewModelScope.launch {
            repository.observeMedia()
                .catch { e ->
                    _uiState.value = _uiState.value.copy(loading = false, error = e.message)
                }
                .collect { items ->
                    _uiState.value = _uiState.value.copy(
                        loading = false,
                        sections = GroupMedia.group(items, _uiState.value.granularity),
                        error = null
                    )
                }
        }
    }

    /** 切换按月 / 按年分组。 */
    fun setGranularity(granularity: GroupMedia.Granularity) {
        viewModelScope.launch {
            val items = runCatching { repository.queryAll() }.getOrDefault(emptyList())
            _uiState.value = _uiState.value.copy(
                granularity = granularity,
                sections = GroupMedia.group(items, granularity)
            )
        }
    }
}
