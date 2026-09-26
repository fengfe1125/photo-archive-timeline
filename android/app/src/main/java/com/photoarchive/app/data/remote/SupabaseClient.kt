package com.photoarchive.app.data.remote

import com.photoarchive.app.BuildConfig
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.storage.Storage

/**
 * Supabase 客户端入口，对应 iOS 端 Services/SupabaseAccount.swift 的 client 初始化。
 *
 * SUPABASE_URL / SUPABASE_ANON_KEY 来自 local.properties，经 BuildConfig 注入。
 * 两者任一为空时 [client] 为 null，UI 层降级为纯本地浏览模式（与 iOS 行为一致）。
 */
object SupabaseProvider {

    const val BUCKET_MEDIA: String = "media"

    val isConfigured: Boolean
        get() = BuildConfig.SUPABASE_URL.isNotBlank() &&
            BuildConfig.SUPABASE_ANON_KEY.isNotBlank() &&
            BuildConfig.SUPABASE_URL.startsWith("http")

    val client: SupabaseClient? by lazy {
        if (!isConfigured) return@lazy null
        runCatching {
            createSupabaseClient(
                supabaseUrl = BuildConfig.SUPABASE_URL,
                supabaseKey = BuildConfig.SUPABASE_ANON_KEY
            ) {
                install(Auth)
                install(Storage)
                install(Postgrest)
            }
        }.getOrNull()
    }

    /** 未配置云端时的统一提示文案，与 iOS 文案对齐。 */
    const val NOT_CONFIGURED_MESSAGE: String = "尚未配置云端连接。你可以继续在本机整理。"
}
