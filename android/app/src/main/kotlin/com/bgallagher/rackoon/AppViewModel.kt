package com.bgallagher.rackoon

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.bgallagher.rackoon.data.AuthKind
import com.bgallagher.rackoon.data.StoredAuth
import com.bgallagher.rackoon.core.DockerSession
import com.bgallagher.rackoon.core.DockerSnapshot
import com.bgallagher.rackoon.core.Server
import com.bgallagher.rackoon.core.ServerSession
import com.bgallagher.rackoon.core.ServerState
import com.bgallagher.rackoon.ssh.HostKeyInfo
import com.bgallagher.rackoon.ssh.SshAuth
import com.bgallagher.rackoon.ssh.SshEndpoint
import com.bgallagher.rackoon.ssh.SshException
import com.bgallagher.rackoon.ssh.SshKeys
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

/** What the Docker screen shows: the first load, the stacks, no Docker, or a failure (with whether the server could not be reached at all). */
sealed class DockerUi {
    object Loading : DockerUi()
    class Ready(val snapshot: DockerSnapshot, val updatedAt: Long?, val error: String?) : DockerUi()
    object NotInstalled : DockerUi()
    class Failed(val message: String, val unreachable: Boolean) : DockerUi()
}

enum class Tab { Overview, Docker, Terminal, More }

/** The sign-in choice in the Add server and Server settings forms. Secrets live here only while the form is open. */
data class AuthFields(
    val kind: AuthKind = AuthKind.Tailscale,
    val password: String = "",
    val keyPem: String? = null,
    val keyName: String? = null,
    val passphrase: String = "",
) {
    fun toStored() = StoredAuth(kind, password.takeIf { kind == AuthKind.Password }, keyPem.takeIf { kind == AuthKind.Key }, passphrase.takeIf { kind == AuthKind.Key && it.isNotEmpty() }, keyName.takeIf { kind == AuthKind.Key })

    /** What is missing or wrong, in words, or null when this can be tried. A key is read now so a bad file or passphrase is caught before connecting. */
    fun problem(): String? = when (kind) {
        AuthKind.Tailscale -> null
        AuthKind.Password -> if (password.isEmpty()) "Enter the password." else null
        AuthKind.Key -> if (keyPem == null) "Choose your private key file." else try { SshKeys.load(keyPem, passphrase.takeIf { it.isNotEmpty() }); null } catch (e: SshException.AuthFailed) { e.detail }
    }
}

/** Server settings: rename, change how Rackoon signs in, forget the trusted host key, remove. */
data class SettingsForm(
    val server: Server,
    val name: String,
    val auth: AuthFields,
    val currentKind: AuthKind,
    val currentKeyName: String?,
    val authChanged: Boolean = false,
    val hostKey: TrustedHostKey?,
    val busy: Boolean = false,
    val error: String? = null,
)

/** The "Add server" form and where it is in its flow. */
data class AddForm(
    val name: String = "",
    val target: String = "",
    val auth: AuthFields = AuthFields(),
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
        val docker = DockerSession(transport)
        val session = ServerSession(transport, cached = c.snapshots.load(server.id), onSnapshot = { c.snapshots.save(server.id, it) })
    }

    private fun endpointOf(server: Server) = SshEndpoint(
        server.host, server.port ?: 22, server.user?.takeIf { it.isNotEmpty() } ?: "root",
        c.secrets.load(server.id)?.toSshAuth() ?: SshAuth.TailscaleNone,
    )


    // MARK: terminals (sessions live in TerminalManager, not here, so they outlast screens)

    val terminals = c.terminals
    private val _highlight = MutableStateFlow(c.prefs.highlightOutput)
    val highlightOutput: StateFlow<Boolean> = _highlight.asStateFlow()

    fun openTerminal(server: Server, theme: com.bgallagher.rackoon.core.TerminalTheme) {
        c.terminals.open(server.id, server.name, endpointOf(server), theme, _highlight.value)
    }

    // MARK: appearance

    private val _themeId = MutableStateFlow(c.prefs.themeId)
    val themeId: StateFlow<String> = _themeId.asStateFlow()
    fun setTheme(id: String) { _themeId.value = id; c.prefs.themeId = id }

    private val _appearance = MutableStateFlow(false)
    val appearance: StateFlow<Boolean> = _appearance.asStateFlow()
    fun showAppearance(show: Boolean) { _appearance.value = show }

    private val _fontSize = MutableStateFlow(c.prefs.terminalFontSize)
    val terminalFontSize: StateFlow<Int> = _fontSize.asStateFlow()

    fun changeFontSize(delta: Int) {
        c.prefs.terminalFontSize = (_fontSize.value + delta).coerceIn(7, 20)
        _fontSize.value = c.prefs.terminalFontSize
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
        c.secrets.remove(server.id)
        c.snapshots.remove(server.id)
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
        _docker.value = DockerUi.Loading
        _openStack.value = null
        // A saved reading shows at once (marked stale) while the first poll runs.
        _overview.value = live!!.session.state.value.takeIf { it.overview != null }?.let { OverviewUi.Ready(it) } ?: OverviewUi.Connecting
    }

    // MARK: Docker (polled every 10 s, only while the Docker tab is on screen: `docker stats` is slow)

    private val _docker = MutableStateFlow<DockerUi>(DockerUi.Loading)
    val docker: StateFlow<DockerUi> = _docker.asStateFlow()

    /** The compose project whose page is open, or null for the list. */
    private val _openStack = MutableStateFlow<String?>(null)
    val openStack: StateFlow<String?> = _openStack.asStateFlow()
    fun openStack(name: String?) { _openStack.value = name }

    suspend fun pollDockerWhileVisible() {
        val l = live ?: return
        while (true) {
            refreshDockerOnce(l)
            delay(10_000)
        }
    }

    fun refreshDockerNow() {
        val l = live ?: return
        viewModelScope.launch { refreshDockerOnce(l) }
    }

    private suspend fun refreshDockerOnce(l: Live) {
        val previous = _docker.value
        try {
            l.transport.connect()
            l.docker.refresh()
            val s = l.docker.state.value
            _docker.value = when {
                s.snapshot != null -> DockerUi.Ready(s.snapshot!!, s.updatedAt, s.error)
                s.error?.contains("not installed", ignoreCase = true) == true -> DockerUi.NotInstalled
                s.error != null -> DockerUi.Failed(s.error!!, unreachable = false)
                else -> DockerUi.Loading
            }
        } catch (e: SshException) {
            // Keep the last stacks on screen when the link drops; with nothing to show, explain.
            _docker.value = if (previous is DockerUi.Ready) DockerUi.Ready(previous.snapshot, previous.updatedAt, e.message)
            else DockerUi.Failed(e.message ?: "Connection failed", unreachable = e is SshException.Unreachable)
        }
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
            val last = l.session.state.value
            val hostKeyProblem = e is SshException.HostKeyChanged || e is SshException.HostKeyUnknown
            // Keep showing the last reading (marked) when the link drops; a host-key problem always takes over the screen.
            _overview.value = if (last.overview != null && !hostKeyProblem) OverviewUi.Ready(last.copy(error = e.message))
            else OverviewUi.Failed(issueOf(l.server.host, l.server.port ?: 22, e))
            return !hostKeyProblem
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
        val endpoint = SshEndpoint.parse(form.target, auth = form.auth.toStored().toSshAuth())
        if (endpoint == null) { editAdd { it.copy(error = "Enter the user and host, like ubuntu@100.64.12.7") }; return }
        form.auth.problem()?.let { problem -> editAdd { it.copy(error = problem) }; return }
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
        val endpoint = SshEndpoint.parse(form.target, auth = form.auth.toStored().toSshAuth()) ?: return
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
            c.secrets.save(server.id, form.auth.toStored())   // before select(): connecting reads it
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

    // MARK: server settings

    private val _settings = MutableStateFlow<SettingsForm?>(null)
    val settings: StateFlow<SettingsForm?> = _settings.asStateFlow()

    fun openSettings() {
        val server = current() ?: return
        val stored = c.secrets.load(server.id)
        _settings.value = SettingsForm(
            server, server.name, AuthFields(stored?.kind ?: AuthKind.Tailscale), stored?.kind ?: AuthKind.Tailscale, stored?.keyName,
            hostKey = c.knownHosts.lookup(server.host, server.port ?: 22),
        )
    }

    fun closeSettings() { _settings.value = null }

    fun editSettings(change: (SettingsForm) -> SettingsForm) { _settings.update { it?.let(change) } }

    /** Saves the name, and a changed sign-in only after it has been tried against the server. */
    fun saveSettings() {
        val form = _settings.value ?: return
        val name = form.name.trim().ifEmpty { form.server.host }
        if (!form.authChanged) {
            updateServer(form.server.copy(name = name)); _settings.value = null; return
        }
        form.auth.problem()?.let { problem -> editSettings { it.copy(error = problem) }; return }
        editSettings { it.copy(busy = true, error = null) }
        val server = form.server
        viewModelScope.launch {
            val stored = form.auth.toStored()
            val endpoint = SshEndpoint(server.host, server.port ?: 22, server.user?.takeIf { it.isNotEmpty() } ?: "root", stored.toSshAuth())
            val test = SshjTransport(endpoint, c.knownHosts)
            try {
                test.connect()
                c.secrets.save(server.id, stored)
                updateServer(server.copy(name = name))
                _settings.value = null
                if (server.id == _selectedId.value) openLive(server.copy(name = name))   // reconnect with the new sign-in
            } catch (e: SshException) {
                editSettings { it.copy(busy = false, error = e.message) }
            } finally {
                test.close()
            }
        }
    }

    private fun updateServer(updated: Server) {
        _servers.update { list -> list.map { if (it.id == updated.id) updated else it } }
        c.servers.save(_servers.value)
    }

    /** Removes the trusted key. The next connection asks to trust whatever the server presents, so use it after the key really changed. */
    fun forgetHostKey() {
        val server = _settings.value?.server ?: return
        c.knownHosts.forget(server.host, server.port ?: 22)
        _settings.value = null
        _tab.value = Tab.Overview
        if (server.id == _selectedId.value) openLive(server)
    }

    fun removeFromSettings() {
        val server = _settings.value?.server ?: return
        _settings.value = null
        remove(server)
    }

    // Last on purpose: openLive() sets state flows declared above, and property initialisers run in order.
    init { current()?.let(::openLive) }

    override fun onCleared() {
        live?.transport?.close()
    }
}
