package com.photoarchive.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CloudDone
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import coil.compose.AsyncImage
import com.photoarchive.app.data.model.MediaItem
import com.photoarchive.app.data.model.UploadState
import com.photoarchive.app.viewmodel.PhotoDetailViewModel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

/**
 * 全屏照片查看，支持双指缩放与拖动，并展示 EXIF 信息与上传按钮。
 * 对应 iOS Features/PhotoDetailView.swift。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PhotoDetailScreen(
    photoId: String,
    navController: NavController,
    viewModel: PhotoDetailViewModel = viewModel()
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    LaunchedEffect(photoId) { viewModel.load(photoId) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(state.item?.displayName?.ifBlank { "照片" } ?: "照片") },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                },
                actions = {
                    val item = state.item
                    if (item != null && state.cloudConfigured) {
                        if (item.isUploaded) {
                            Icon(
                                Icons.Filled.CloudDone,
                                contentDescription = "已上传",
                                modifier = Modifier.padding(horizontal = 12.dp)
                            )
                        } else {
                            IconButton(onClick = viewModel::upload) {
                                Icon(Icons.Filled.CloudUpload, contentDescription = "上传原片")
                            }
                        }
                    }
                }
            )
        }
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(Color.Black),
                contentAlignment = Alignment.Center
            ) {
                when {
                    state.loading -> CircularProgressIndicator()
                    state.item == null -> Text(
                        text = state.error ?: "照片不可用。",
                        color = Color.White
                    )
                    else -> ZoomableImage(uri = state.item!!.uri)
                }
            }

            UploadStatusBar(state.uploadState)
            state.item?.let { MetadataPanel(it, cloudConfigured = state.cloudConfigured) }
        }
    }
}

/** 手势缩放（transformable）+ 拖动。 */
@Composable
private fun ZoomableImage(uri: String) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }

    val transformState = rememberTransformableState { zoomChange, panChange, _ ->
        scale = (scale * zoomChange).coerceIn(1f, 6f)
        if (scale > 1f) {
            offsetX += panChange.x
            offsetY += panChange.y
        } else {
            offsetX = 0f
            offsetY = 0f
        }
    }

    AsyncImage(
        model = uri,
        contentDescription = "照片",
        contentScale = ContentScale.Fit,
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer(
                scaleX = scale,
                scaleY = scale,
                translationX = offsetX,
                translationY = offsetY
            )
            .transformable(state = transformState)
    )
}

@Composable
private fun UploadStatusBar(uploadState: UploadState) {
    when (uploadState) {
        is UploadState.Idle -> Unit
        is UploadState.Preparing -> Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Text("正在准备上传…", style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(4.dp))
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
        is UploadState.Progress -> Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Text(
                "上传中 ${(uploadState.fraction * 100).roundToInt()}%",
                style = MaterialTheme.typography.bodySmall
            )
            Spacer(Modifier.height(4.dp))
            LinearProgressIndicator(
                progress = { uploadState.fraction },
                modifier = Modifier.fillMaxWidth()
            )
        }
        is UploadState.Success -> Text(
            "原片已上传到云端。",
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(12.dp)
        )
        is UploadState.Failed -> Text(
            uploadState.message,
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(12.dp)
        )
    }
}

/** EXIF / 元数据展示。 */
@Composable
private fun MetadataPanel(item: MediaItem, cloudConfigured: Boolean) {
    val formatter = remember { SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()) }
    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        MetadataRow("拍摄时间", if (item.dateTaken > 0) formatter.format(Date(item.dateTaken)) else "未知")
        MetadataRow("类型", item.mimeType)
        if (item.width > 0 && item.height > 0) {
            MetadataRow("尺寸", "${item.width} × ${item.height}")
        }
        if (item.sizeBytes > 0) {
            MetadataRow("大小", "%.1f MB".format(item.sizeBytes / 1024.0 / 1024.0))
        }
        item.duration?.let { MetadataRow("时长", "${it / 1000} 秒") }
        if (item.hasLocation) {
            MetadataRow("位置", "%.5f, %.5f".format(item.latitude, item.longitude))
        }
        if (!cloudConfigured) {
            Spacer(Modifier.height(8.dp))
            Text(
                "尚未配置云端连接。你可以继续在本机整理。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun MetadataRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(
            text = label,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(0.3f)
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.weight(0.7f)
        )
    }
}
