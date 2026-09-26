package com.photoarchive.app.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.photoarchive.app.ui.screens.LibraryScreen
import com.photoarchive.app.ui.screens.PhotoDetailScreen
import com.photoarchive.app.ui.screens.StoriesScreen
import com.photoarchive.app.ui.screens.MapScreen
import com.photoarchive.app.ui.screens.SettingsScreen

sealed class Screen(val route: String) {
    object Library : Screen("library")
    object PhotoDetail : Screen("photo_detail/{photoId}") {
        fun createRoute(photoId: String) = "photo_detail/$photoId"
    }
    object Stories : Screen("stories")
    object Map : Screen("map")
    object Settings : Screen("settings")
}

@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    NavHost(navController = navController, startDestination = Screen.Library.route) {
        composable(Screen.Library.route) {
            LibraryScreen(navController = navController)
        }
        composable(Screen.PhotoDetail.route) { backStackEntry ->
            val photoId = backStackEntry.arguments?.getString("photoId") ?: ""
            PhotoDetailScreen(photoId = photoId, navController = navController)
        }
        composable(Screen.Stories.route) {
            StoriesScreen(navController = navController)
        }
        composable(Screen.Map.route) {
            MapScreen(navController = navController)
        }
        composable(Screen.Settings.route) {
            SettingsScreen(navController = navController)
        }
    }
}
