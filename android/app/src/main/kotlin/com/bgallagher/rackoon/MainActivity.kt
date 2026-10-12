package com.bgallagher.rackoon

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import com.bgallagher.rackoon.ui.RackoonRoot
import com.bgallagher.rackoon.ui.theme.RackoonTheme

class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RackoonTheme {
                RackoonRoot(viewModel)
            }
        }
    }
}
