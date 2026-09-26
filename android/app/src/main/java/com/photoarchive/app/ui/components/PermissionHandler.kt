package com.photoarchive.app.ui.components

import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import com.photoarchive.app.data.repository.MediaRepository

/**
 * 媒体读取权限请求组件。
 *
 * - Android 13 (API 33)+：READ_MEDIA_IMAGES + READ_MEDIA_VIDEO
 * - Android 12 (API 32) 及以下：READ_EXTERNAL_STORAGE
 *
 * 权限通过后渲染 [content]，否则展示引导按钮。
 */
@Composable
fun MediaPermissionGate(
    onGranted: () -> Unit = {},
    onDenied: () -> Unit = {},
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    val permissions = remember { MediaRepository.requiredPermissions() }

    var granted by remember { mutableStateOf(hasMediaPermission(context, permissions)) }
    var requested by remember { mutableStateOf(false) }

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { result ->
        // 部分授权（Android 14 的”选中的照片“）也视为可用
        granted = result.values.any { it }
        if (granted) onGranted() else onDenied()
    }

    LaunchedEffect(Unit) {
        if (granted) {
            onGranted()
        } else if (!requested) {
            requested = true
            launcher.launch(permissions.toTypedArray())
        }
    }

    if (granted) {
        content()
    } else {
        Column(
            modifier = Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "需要相册访问权限才能整理你的照片。",
                textAlign = TextAlign.Center
            )
            Button(
                onClick = { launcher.launch(permissions.toTypedArray()) },
                modifier = Modifier.padding(top = 16.dp)
            ) {
                Text("授予权限")
            }
        }
    }
}

private fun hasMediaPermission(context: Context, permissions: List<String>): Boolean =
    permissions.any { permission ->
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }
