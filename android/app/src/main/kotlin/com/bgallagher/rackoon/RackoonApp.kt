package com.bgallagher.rackoon

import android.app.Application
import com.bgallagher.rackoon.data.AppContainer
import com.bgallagher.rackoon.demo.DemoBuild
import com.bgallagher.rackoon.ssh.SshProviders

class RackoonApp : Application() {
    lateinit var container: AppContainer
        private set

    /**
     * Switches this process to demo mode (debug builds only; a no-op when there is none). Call it before anything has used the
     * container: the demo is started with `adb shell am force-stop <app>` then `am start --ez demo true`.
     */
    fun enterDemo() {
        val hooks = DemoBuild.hooks ?: return
        if (!container.isDemo) container = AppContainer(this, hooks)
    }

    override fun onCreate() {
        super.onCreate()
        // The platform's cut-down BouncyCastle must be replaced before the first SSH connection.
        SshProviders.install()
        container = AppContainer(this)
    }
}
