package com.photoarchive.app.ui.screens

import android.preference.PreferenceManager
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.photoarchive.app.navigation.Screen
import com.photoarchive.app.ui.components.MediaPermissionGate
import com.photoarchive.app.viewmodel.LibraryViewModel
import org.osmdroid.config.Configuration
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker

/**
 * 在地图上展示带地理位置的照片。
 * 使用 OSMDroid（OpenStreetMap），无需任何 API key。
 * 对应 iOS Features/MapAndSettings.swift 的地图部分。
 *
 * 注意：Android 10+ 的 MediaStore 不再直接提供经纬度（位置脉络），
 * 因此大多数新设备上这里会为空，需后续用 ExifInterface 对已授权原文件补充读取。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MapScreen(
    navController: NavController,
    viewModel: LibraryViewModel = viewModel()
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current

    DisposableEffect(Unit) {
        Configuration.getInstance().load(
            context,
            PreferenceManager.getDefaultSharedPreferences(context)
        )
        // 避免被 OSM 默认 UA 限流
        Configuration.getInstance().userAgentValue = context.packageName
        onDispose { }
    }

    val located = remember(state.sections) {
        state.sections.flatMap { it.items }.filter { it.hasLocation }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("地图") },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        MediaPermissionGate(onGranted = viewModel::onPermissionGranted) {
            Box(modifier = Modifier.fillMaxSize().padding(padding)) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        MapView(ctx).apply {
                            setTileSource(TileSourceFactory.MAPNIK)
                            setMultiTouchControls(true)
                            controller.setZoom(3.0)
                        }
                    },
                    update = { mapView ->
                        mapView.overlays.clear()
                        located.forEach { item ->
                            val point = GeoPoint(item.latitude!!, item.longitude!!)
                            mapView.overlays.add(
                                Marker(mapView).apply {
                                    position = point
                                    title = item.displayName.ifBlank { "照片位置" }
                                    setOnMarkerClickListener { _, _ ->
                                        navController.navigate(Screen.PhotoDetail.createRoute(item.id))
                                        true
                                    }
                                }
                            )
                        }
                        located.firstOrNull()?.let {
                            mapView.controller.setCenter(GeoPoint(it.latitude!!, it.longitude!!))
                            mapView.controller.setZoom(10.0)
                        }
                        mapView.invalidate()
                    }
                )

                if (located.isEmpty()) {
                    Text(
                        text = "还没有带位置信息的照片。",
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.align(Alignment.TopCenter).padding(16.dp)
                    )
                }
            }
        }
    }
}
