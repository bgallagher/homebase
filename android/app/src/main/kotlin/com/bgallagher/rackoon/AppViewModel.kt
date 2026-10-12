package com.bgallagher.rackoon

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.core.ServerSession
import com.bgallagher.rackoon.core.ServerState
import com.bgallagher.rackoon.ssh.HostKeyInfo
import com.bgallagher.rackoon.ssh.SshAuth
import com.bgallagher.rackoon.ssh.SshEndpoint
import com.bgallagher.rackoon.ssh.SshException
import com.bgallagher.rackoon.ssh.SshjTransport
import com.bgallagher.rackoon.ssh.TrustedHostKey
import com.bgallagher.rackoon.ssh.scanHostKey
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.UUID

/** Why a server cannot be shown, in terms the screen can explain. */
sealed class Issue {
    class Unreachable(val detail: String) : Issue()
    class AuthFailed(val detail: String) : Issue()
    class KeyChanged(val host: String, val trusted: TrustedHostKey, val presented: HostKeyInfo) : Issue()
    class KeyUnknown(val host: String, val port: Int, val presented: HostKeyInfo) : Issue()
    class Other(val detail: String) : Issue()
}

sealed class OverviewUi {
    object Connecting : OverviewUi()
    class Ready(val state: ServerState) : OverviewUi()
    class Failed(val issue: Issue) : OverviewUi()
}

enum class Tab { Overview, Terminal, More }

/** The "Add server" form and where it is in its flow. */
data class AddForm(
    val name: String = "",
    val target: String = "",
    val busy: Boolean = false,
    val error: String? = null,
    /** Set while the user is deciding whether to trust a first-seen host key. */
    val trust: HostKeyInfo? = null,
    /** Set when the server presented a different key than the one trusted: the connection is blocked. */
    val blocked: Issue.KeyChanged? = null,
)

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val c = (application as RackoonApp).container

    private val _servers = MutableStateFlow(c.servers.load())
    val servers: StateFlow<List<Server>> = _servers.asStateFlow()

    private val _selectedId = MutableStateFlow(c.prefs.selectedServerId?.takeIf { id -> _servers.value.any { it.id == id } } ?: _servers.value.firstOrNull()?.id)
    val selectedId: StateFlow<String?> = _selectedId.asStateFlow()

    private fun current(): Server? = _servers.value.firstOrNull { it.id == _selectedId.value }

    /** The server on screen, kept in step with the list and the selection. */
    val selectedServer: StateFlow<Server?> = combine(_servers, _selectedId) { list, id -> list.firstOrNull { it.id == id } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, current())

    private val _readOnly = MutableStateFlow(c.prefs.readOnly)
    val readOnly: StateFlow<Boolean> = _readOnly.asStateFlow()

    private val _firstRun = MutableStateFlow(!c.prefs.firstRunDone)
    val firstRun: StateFlow<Boolean> = _firstRun.asStateFlow()

    private val _tab = MutableStateFlow(Tab.Overview)
    val tab: StateFlow<Tab> = _tab.asStateFlow()

    private val _overview = MutableStateFlow<OverviewUi>(OverviewUi.Connecting)
    val overview: StateFlow<OverviewUi> = _overview.asStateFlow()

    private val _switcher = MutableStateFlow(false)
    val switcher: StateFlow<Boolean> = _switcher.asStateFlow()

    private val _add = MutableStateFlow<AddForm?>(null)
    val add: StateFlow<AddForm?> = _add.asStateFlow()

    /** Statuses for the switcher: the selected server's live state, others unknown. */
    private var live: Live? = null
    private var pollJob: Job? = null

    private inner class Live(val server: Server) {
        val transport = SshjTransport(endpointOf(server), c.knownHosts)
        val session = ServerSession(transport)
    }

    private fun endpointOf(server: Server) =
        SshEndpoint(server.host, server.port ?: 22, server.user?.takeIf { it.isNotEmpty() } ?: "root", SshAuth.TailscaleNone)

    init { current()?.let(::openLive) }

    // MARK: terminals (sessions live in TerminalManager, not here, so they outlast screens)

    val terminals = c.terminals
    private val _highlight = MutableStateFlow(c.prefs.highlightOutput)
    val highlightOutput: StateFlow<Boolean> = _highlight.asStateFlow()

    fun openTerminal(server: Server, theme: com.bgallagher.rackoon.core.TerminalTheme) {
        c.terminals.open(server.id, server.name, endpointOf(server), theme, _highlight.value)
    }

    fun setHighlight(on: Boolean) {
        _highlight.value = on; c.prefs.highlightOutput = on; c.terminals.setHighlight(on)
    }

    // MARK: first run, read-only, tabs

    fun dismissFirstRun() { c.prefs.firstRunDone = true; _firstRun.value = false }
    fun toggleReadOnly() { _readOnly.update { !it }; c.prefs.readOnly = _readOnly.value }
    fun showTab(tab: Tab) { _tab.value = tab }
    fun showSwitcher(show: Boolean) { _switcher.value = show }

    // MARK: servers

    fun select(server: Server) {
        _switcher.value = false
        if (server.id == _selectedId.value && live != null) return
        _selectedId.value = server.id
        c.prefs.selectedServerId = server.id
        openLive(server)
    }

    fun remove(server: Server) {
        c.terminals.closeAll(server.id)
        c.knownHosts.forget(server.host, server.port ?: 22)
        _servers.update { list -> list.filterNot { it.id == server.id } }
        c.servers.save(_servers.value)
        if (_selectedId.value == server.id) {
            live?.transport?.close(); live = null; pollJob?.cancel()
            _selectedId.value = _servers.value.firstOrNull()?.id
            c.prefs.selectedServerId = _selectedId.value
            _servers.value.firstOrNull()?.let(::openLive)
        }
    }

    private fun openLive(server: Server) {
        pollJob?.cancel()
        live?.transport?.close()
        live = Live(server)
        _overview.value = OverviewUi.Connecting
    }

    // MARK: Overview polling (the screen runs this only while it is visible)

    /** Polls the selected server until cancelled. A refused host key stops it (nothing is retried against a changed key). */
    suspend fun pollWhileVisible() {
        val l = live ?: return
        while (true) {
            val keepGoing = refreshOnce(l)
            if (!keepGoing) return
            delay(5_000)
        }
    }

    fun refreshNow() {
        val l = live ?: return
        viewModelScope.launch { refreshOnce(l) }
    }

    private suspend fun refreshOnce(l: Live): Boolean {
        try {
            l.transport.connect()
            l.session.refresh()
            val s = l.session.state.value
            _overview.value = when {
                s.overview == null && s.error != null -> OverviewUi.Failed(Issue.Other(s.error!!))
                s.overview != null -> OverviewUi.Ready(s)
                else -> OverviewUi.Connecting
            }
            return true
        } catch (e: SshException) {
            _overview.value = OverviewUi.Failed(issueOf(l.server.host, l.server.port ?: 22, e))
            return e !is SshException.HostKeyChanged && e !is SshException.HostKeyUnknown
        }
    }

    private fun issueOf(host: String, port: Int, e: SshException): Issue = when (e) {
        is SshException.HostKeyChanged -> Issue.KeyChanged(host, e.trusted, e.presented)
        is SshException.HostKeyUnknown -> Issue.KeyUnknown(host, port, e.presented)
        is SshException.AuthFailed -> Issue.AuthFailed(e.detail)
        is SshException.Unreachable -> Issue.Unreachable(e.detail)
        else -> Issue.Other(e.message ?: "Connection failed")
    }

    /** The user trusted a key that an already-saved server presented for the first time (for example after "Forget"). */
    fun trustPresented(issue: Issue.KeyUnknown) {
        c.knownHosts.trust(issue.host, issue.port, issue.presented)
        refreshNow()
    }

    // MARK: add server

    fun startAdd() { _switcher.value = false; _add.value = AddForm() }
    fun cancelAdd() { _add.value = null }
    fun editAdd(change: (AddForm) -> AddForm) { _add.update { it?.let(change) } }

    fun submitAdd() {
        val form = _add.value ?: return
        val endpoint = SshEndpoint.parse(form.target)
        if (endpoint == null) { editAdd { it.copy(error = "Enter the user and host, like ubuntu@100.64.12.7") }; return }
        editAdd { it.copy(busy = true, error = null) }
        viewModelScope.launch {
            try {
                if (c.knownHosts.lookup(endpoint.host, endpoint.port) == null) {
                    val key = scanHostKey(endpoint.host, endpoint.port)
                    editAdd { it.copy(busy = false, trust = key) }
                } else {
                    connectAndSave(endpoint)
                }
            } catch (e: SshException) {
                editAdd { it.copy(busy = false, error = e.message) }
            }
        }
    }

    fun trustAndConnect() {
        val form = _add.value ?: return
        val key = form.trust ?: return
        val endpoint = SshEndpoint.parse(form.target) ?: return
        c.knownHosts.trust(endpoint.host, endpoint.port, key)
        editAdd { it.copy(trust = null, busy = true) }
        viewModelScope.launch { connectAndSave(endpoint) }
    }

    fun declineTrust() { editAdd { it.copy(trust = null) } }

    private suspend fun connectAndSave(endpoint: SshEndpoint) {
        val form = _add.value ?: return
        val transport = SshjTransport(endpoint, c.knownHosts)
        try {
            transport.connect()
            val server = Server(
                id = UUID.randomUUID().toString(), name = form.name.trim().ifEmpty { endpoint.host }, host = endpoint.host,
                user = endpoint.user, port = endpoint.port.takeIf { it != 22 },
            )
            _servers.update { it + server }
            c.servers.save(_servers.value)
            _add.value = null
            select(server)
        } catch (e: SshException.HostKeyChanged) {
            editAdd { it.copy(busy = false, blocked = Issue.KeyChanged(endpoint.host, e.trusted, e.presented)) }
        } catch (e: SshException) {
            editAdd { it.copy(busy = false, error = e.message) }
        } finally {
            transport.close()
        }
    }

    override fun onCleared() {
        live?.transport?.close()
    }
}
