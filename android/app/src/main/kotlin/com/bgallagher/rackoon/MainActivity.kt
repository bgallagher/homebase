package com.bgallagher.rackoon

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bgallagher.rackoon.ui.RackoonRoot
import com.bgallagher.rackoon.ui.theme.RackoonTheme

class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // `am start --ez demo true` on a debug build: the app runs against made-up servers (see demo/). Ignored in release builds.
        if (intent.getBooleanExtra("demo", false)) (application as RackoonApp).enterDemo()
        enableEdgeToEdge()
        setContent {
            val themeId by viewModel.themeId.collectAsStateWithLifecycle()
            RackoonTheme(themeId) {
                RackoonRoot(viewModel)
            }
        }
    }
}
