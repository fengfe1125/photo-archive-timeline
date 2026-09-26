package com.photoarchive.app.data.repository

import com.photoarchive.app.data.model.AccountState
import com.photoarchive.app.data.remote.SupabaseProvider
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.providers.builtin.OTP
import io.github.jan.supabase.auth.status.SessionStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map

/**
 * 账户认证，对应 iOS 端 Services/SupabaseAccount.swift。
 * 支持邮箱密码登录与邮箱 OTP（iOS 用的是 OTP 链路）。
 */
class AuthRepository {

    private val client = SupabaseProvider.client

    val isConfigured: Boolean get() = client != null

    /** 登录状态流，对应 iOS 的 authStateChanges 观察。 */
    val accountState: Flow<AccountState> =
        client?.auth?.sessionStatus?.map { status ->
            when (status) {
                is SessionStatus.Authenticated -> AccountState.SignedIn(
                    userId = status.session.user?.id.orEmpty(),
                    email = status.session.user?.email
                )
                else -> AccountState.SignedOut
            }
        } ?: flowOf(AccountState.NotConfigured)

    suspend fun signInWithPassword(email: String, password: String): Result<Unit> = runCatching {
        val auth = requireClient().auth
        auth.signInWith(Email) {
            this.email = email.trim()
            this.password = password
        }
    }

    suspend fun signUpWithPassword(email: String, password: String): Result<Unit> = runCatching {
        val auth = requireClient().auth
        auth.signUpWith(Email) {
            this.email = email.trim()
            this.password = password
        }
        Unit
    }

    /** 发送邮箱验证码（对应 iOS signInWithOTP）。 */
    suspend fun sendEmailOtp(email: String): Result<Unit> = runCatching {
        requireClient().auth.signInWith(OTP) {
            this.email = email.trim()
        }
    }

    /** 校验邮箱验证码（对应 iOS verifyOTP）。 */
    suspend fun verifyEmailOtp(email: String, token: String): Result<Unit> = runCatching {
        requireClient().auth.verifyEmailOtp(
            type = io.github.jan.supabase.auth.OtpType.Email.EMAIL,
            email = email.trim(),
            token = token.trim()
        )
    }

    suspend fun signOut(): Result<Unit> = runCatching {
        requireClient().auth.signOut()
    }

    fun currentUserId(): String? = client?.auth?.currentUserOrNull()?.id

    fun currentEmail(): String? = client?.auth?.currentUserOrNull()?.email

    private fun requireClient() =
        client ?: error(SupabaseProvider.NOT_CONFIGURED_MESSAGE)
}
