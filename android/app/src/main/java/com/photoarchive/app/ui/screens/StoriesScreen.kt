package com.photoarchive.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import coil.compose.AsyncImage
import com.photoarchive.app.data.model.MediaSection
import com.photoarchive.app.domain.usecase.GroupMedia
import com.photoarchive.app.navigation.Screen
import com.photoarchive.app.ui.components.MediaPermissionGate
import com.photoarchive.app.viewmodel.StoriesViewModel

/**
 * 时间线故事视图，按月 / 年分组滚动。
 * 对应 iOS Features/StoriesView.swift。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StoriesScreen(
    navController: NavController,
    viewModel: StoriesViewModel = viewModel()
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("故事") },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        MediaPermissionGate(onGranted = viewModel::start) {
            Column(modifier = Modifier.fillMaxSize().padding(padding)) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    GranularityChip("按月", GroupMedia.Granularity.MONTH, state.granularity, viewModel::setGranularity)
                    GranularityChip("按年", GroupMedia.Granularity.YEAR, state.granularity, viewModel::setGranularity)
                    GranularityChip("按天", GroupMedia.Granularity.DAY, state.granularity, viewModel::setGranularity)
                }

                when {
                    state.loading -> Box(Modifier.fillMaxSize(), Alignment.Center) {
                        CircularProgressIndicator()
                    }
                    state.sections.isEmpty() -> Box(Modifier.fillMaxSize(), Alignment.Center) {
                        Text(state.error ?: "还没有可回顾的故事。")
                    }
                    else -> LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 24.dp)
                    ) {
                        items(state.sections, key = { it.key }) { section ->
                            StorySection(section) { photoId ->
                                navController.navigate(Screen.PhotoDetail.createRoute(photoId))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GranularityChip(
    label: String,
    value: GroupMedia.Granularity,
    current: GroupMedia.Granularity,
    onSelect: (GroupMedia.Granularity) -> Unit
) {
    FilterChip(
        selected = value == current,
        onClick = { onSelect(value) },
        label = { Text(label) }
    )
}

@Composable
private fun StorySection(section: MediaSection, onOpen: (String) -> Unit) {
    Column(modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
        Column(modifier = Modifier.padding(horizontal = 16.dp)) {
            Text(section.label, style = MaterialTheme.typography.titleLarge)
            Text(
                "${section.items.size} 项回忆",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        LazyRow(
            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(section.items.take(20), key = { it.id }) { item ->
                AsyncImage(
                    model = item.uri,
                    contentDescription = item.displayName.ifBlank { "照片" },
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(140.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .clickable { onOpen(item.id) }
                )
            }
        }
    }
}
