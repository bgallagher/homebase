package com.bgallagher.rackoon

import android.app.Application
import com.bgallagher.rackoon.data.AppContainer
import com.bgallagher.rackoon.ssh.SshProviders

class RackoonApp : Application() {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        // The platform's cut-down BouncyCastle must be replaced before the first SSH connection.
        SshProviders.install()
        container = AppContainer(this)
    }
}
