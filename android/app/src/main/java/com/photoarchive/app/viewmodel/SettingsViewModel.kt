package com.photoarchive.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.photoarchive.app.data.model.AccountState
import com.photoarchive.app.data.model.UploadState
import com.photoarchive.app.data.remote.SupabaseProvider
import com.photoarchive.app.data.repository.AuthRepository
import com.photoarchive.app.data.repository.MediaRepository
import com.photoarchive.app.data.repository.UploadRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SettingsUiState(
    val cloudConfigured: Boolean = SupabaseProvider.isConfigured,
    val account: AccountState = AccountState.NotConfigured,
    val autoSyncEnabled: Boolean = false,
    val wifiOnly: Boolean = true,
    val localItemCount: Int = 0,
    val localBytes: Long = 0L,
    val busy: Boolean = false,
    val message: String? = null,
    val otpSentTo: String? = null,
    val syncProgress: String? = null
)

/** 同步设置 + 账户状态，对应 iOS Features/MapAndSettings.swift 与 LiveSettingsView.swift。 */
class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val authRepository = AuthRepository()
    private val mediaRepository = MediaRepository(application)
    private val uploadRepository = UploadRepository(application, authRepository)

    private val _uiState = MutableStateFlow(SettingsUiState())
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            authRepository.accountState.collect { state ->
                _uiState.value = _uiState.value.copy(account = state)
            }
        }
        refreshStorageUsage()
    }

    /** 统计本地媒体数量与存储用量。 */
    fun refreshStorageUsage() {
        viewModelScope.launch {
            val items = runCatching { mediaRepository.queryAll() }.getOrDefault(emptyList())
            _uiState.value = _uiState.value.copy(
                localItemCount = items.size,
                localBytes = items.sumOf { it.sizeBytes }
            )
        }
    }

    fun setAutoSync(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(autoSyncEnabled = enabled)
    }

    fun setWifiOnly(enabled: Boolean) {
        _uiState.value = _uiState.value.copy(wifiOnly = enabled)
    }

    fun signInWithPassword(email: String, password: String) {
        runAuth { authRepository.signInWithPassword(email, password) }
    }

    fun sendEmailOtp(email: String) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(busy = true, message = null)
            val result = authRepository.sendEmailOtp(email)
            _uiState.value = _uiState.value.copy(
                busy = false,
                otpSentTo = if (result.isSuccess) email else null,
                message = if (result.isSuccess) "验证码已发送到 $email" else result.exceptionOrNull()?.message
            )
        }
    }

    fun verifyEmailOtp(token: String) {
        val email = _uiState.value.otpSentTo ?: return
        runAuth { authRepository.verifyEmailOtp(email, token) }
    }

    fun signOut() {
        runAuth { authRepository.signOut() }
    }

    /** 将本地未上传媒体批量同步到云端。 */
    fun syncNow() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(busy = true, syncProgress = "正在准备…")
            val items = runCatching { mediaRepository.queryAll() }.getOrDefault(emptyList())
            var done = 0
            var failed = 0
            uploadRepository.uploadAll(items).collect { (_, state) ->
                when (state) {
                    is UploadState.Success -> {
                        done++
                        _uiState.value = _uiState.value.copy(syncProgress = "已上传 $done / ${items.size}")
                    }
                    is UploadState.Failed -> failed++
                    else -> Unit
                }
            }
            _uiState.value = _uiState.value.copy(
                busy = false,
                syncProgress = null,
                message = "同步结束：成功 $done 项，失败 $failed 项。"
            )
        }
    }

    fun clearMessage() {
        _uiState.value = _uiState.value.copy(message = null)
    }

    private fun runAuth(block: suspend () -> Result<Unit>) {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(busy = true, message = null)
            val result = block()
            _uiState.value = _uiState.value.copy(
                busy = false,
                message = result.exceptionOrNull()?.message,
                otpSentTo = if (result.isSuccess) null else _uiState.value.otpSentTo
            )
        }
    }
}
