package com.bgallagher.rackoon.terminal

import android.content.Context
import android.content.Intent
import com.bgallagher.rackoon.core.TerminalTheme
import com.bgallagher.rackoon.ssh.SshEndpoint
import com.bgallagher.rackoon.ssh.ServerConnection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update

/**
 * Every open terminal, per server, for the life of the process (not the screen): switching tabs or servers never ends a
 * session. Each server gets its own SSH connection, separate from the Overview poll. A foreground service keeps the process
 * alive while any tab is open, so sessions survive the screen turning off.
 */
class TerminalManager(private val context: Context, private val connect: (SshEndpoint) -> ServerConnection) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val transports = HashMap<String, ServerConnection>()
    private var nextId = 1

    private val _tabs = MutableStateFlow<Map<String, List<TerminalTab>>>(emptyMap())
    val tabs: StateFlow<Map<String, List<TerminalTab>>> = _tabs.asStateFlow()
    private val _selected = MutableStateFlow<Map<String, Int>>(emptyMap())
    val selected: StateFlow<Map<String, Int>> = _selected.asStateFlow()

    /** How many sessions are open across all servers (the notification text). */
    val openCount: StateFlow<Int> = _tabs.map { m -> m.values.sumOf { it.size } }.stateIn(scope, SharingStarted.Eagerly, 0)

    fun open(serverId: String, serverName: String, endpoint: SshEndpoint, theme: TerminalTheme, highlight: Boolean, command: String? = null, title: String? = null): TerminalTab {
        val transport = synchronized(transports) { transports.getOrPut(serverId) { connect(endpoint) } }
        val number = (_tabs.value[serverId]?.size ?: 0) + 1
        val tab = TerminalTab(nextId++, title ?: if (number == 1) serverName else "$serverName $number", transport, scope, theme, highlight, command)
        val wasEmpty = _tabs.value.values.all { it.isEmpty() }
        _tabs.update { it + (serverId to (it[serverId].orEmpty() + tab)) }
        _selected.update { it + (serverId to tab.id) }
        if (wasEmpty) context.startForegroundService(Intent(context, SessionService::class.java))
        return tab
    }

    fun select(serverId: String, tab: TerminalTab) { _selected.update { it + (serverId to tab.id) } }

    fun close(serverId: String, tab: TerminalTab) {
        tab.close()
        val remaining = _tabs.value[serverId].orEmpty().filterNot { it.id == tab.id }
        _tabs.update { if (remaining.isEmpty()) it - serverId else it + (serverId to remaining) }
        _selected.update { if (_selected.value[serverId] == tab.id) it + (serverId to (remaining.lastOrNull()?.id ?: -1)) else it }
        if (remaining.isEmpty()) synchronized(transports) { transports.remove(serverId)?.close() }
    }

    /** A server was removed: end its sessions. */
    fun closeAll(serverId: String) {
        _tabs.value[serverId].orEmpty().forEach { close(serverId, it) }
    }

    fun applyTheme(theme: TerminalTheme) { _tabs.value.values.flatten().forEach { it.applyTheme(theme) } }
    fun setHighlight(on: Boolean) { _tabs.value.values.flatten().forEach { it.setHighlight(on) } }

    fun closeEverything() { _tabs.value.forEach { (id, list) -> list.forEach { close(id, it) } } }
}
