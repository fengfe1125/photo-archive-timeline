package com.photoarchive.app.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.photoarchive.app.data.model.AccountState
import com.photoarchive.app.viewmodel.SettingsViewModel

/**
 * 账户登录/登出、同步开关、存储用量。
 * 对应 iOS Features/MapAndSettings.swift 与 LiveSettingsView.swift。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    navController: NavController,
    viewModel: SettingsViewModel = viewModel()
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("设置") },
                navigationIcon = {
                    IconButton(onClick = { navController.popBackStack() }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            AccountCard(state, viewModel)
            SyncCard(state, viewModel)
            StorageCard(state)

            state.message?.let { message ->
                Text(
                    text = message,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error
                )
                OutlinedButton(onClick = viewModel::clearMessage) { Text("知道了") }
            }
        }
    }
}

@Composable
private fun AccountCard(
    state: com.photoarchive.app.viewmodel.SettingsUiState,
    viewModel: SettingsViewModel
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("账户", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))

            when (val account = state.account) {
                is AccountState.NotConfigured -> Text(
                    "尚未配置云端连接。请在 local.properties 填入 SUPABASE_URL 与 SUPABASE_ANON_KEY 后重新构建。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                is AccountState.SignedIn -> {
                    Text(account.email ?: account.userId, style = MaterialTheme.typography.bodyMedium)
                    Spacer(Modifier.height(8.dp))
                    OutlinedButton(
                        onClick = viewModel::signOut,
                        enabled = !state.busy
                    ) { Text("退出登录") }
                }

                is AccountState.SignedOut -> SignInForm(state, viewModel)
            }
        }
    }
}

@Composable
private fun SignInForm(
    state: com.photoarchive.app.viewmodel.SettingsUiState,
    viewModel: SettingsViewModel
) {
    var email by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var token by remember { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = email,
            onValueChange = { email = it },
            label = { Text("邮箱") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        if (state.otpSentTo == null) {
            OutlinedTextField(
                value = password,
                onValueChange = { password = it },
                label = { Text("密码（可选，留空则用邮箱验证码）") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        if (password.isBlank()) {
                            viewModel.sendEmailOtp(email)
                        } else {
                            viewModel.signInWithPassword(email, password)
                        }
                    },
                    enabled = !state.busy && email.isNotBlank()
                ) { Text(if (password.isBlank()) "发送验证码" else "登录") }
            }
        } else {
            OutlinedTextField(
                value = token,
                onValueChange = { token = it },
                label = { Text("邮箱验证码") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            Button(
                onClick = { viewModel.verifyEmailOtp(token) },
                enabled = !state.busy && token.isNotBlank()
            ) { Text("验证并登录") }
        }

        if (state.busy) {
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun SyncCard(
    state: com.photoarchive.app.viewmodel.SettingsUiState,
    viewModel: SettingsViewModel
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("同步", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))

            SwitchRow(
                label = "自动同步新照片",
                checked = state.autoSyncEnabled,
                enabled = state.account is AccountState.SignedIn,
                onCheckedChange = viewModel::setAutoSync
            )
            HorizontalDivider(modifier = Modifier.padding(vertical = 4.dp))
            SwitchRow(
                label = "仅在 Wi-Fi 下同步",
                checked = state.wifiOnly,
                enabled = state.account is AccountState.SignedIn,
                onCheckedChange = viewModel::setWifiOnly
            )

            Spacer(Modifier.height(12.dp))
            Button(
                onClick = viewModel::syncNow,
                enabled = !state.busy && state.account is AccountState.SignedIn
            ) { Text("立即同步") }

            state.syncProgress?.let {
                Spacer(Modifier.height(8.dp))
                Text(it, style = MaterialTheme.typography.bodySmall)
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun StorageCard(state: com.photoarchive.app.viewmodel.SettingsUiState) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("存储用量", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            Text("本地媒体：${state.localItemCount} 项", style = MaterialTheme.typography.bodyMedium)
            Text(
                "占用空间：%.2f GB".format(state.localBytes / 1024.0 / 1024.0 / 1024.0),
                style = MaterialTheme.typography.bodyMedium
            )
        }
    }
}

@Composable
private fun SwitchRow(
    label: String,
    checked: Boolean,
    enabled: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}
