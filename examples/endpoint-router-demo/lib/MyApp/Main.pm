package MyApp::Main;
use parent 'PAGI::Endpoint::Router';
use strict;
use warnings;
use Future::AsyncAwait;

use MyApp::API;
use PAGI::App::File;
use File::Spec;
use File::Basename qw(dirname);

sub routes {
    my ($self, $r) = @_;

    # Home page
    $r->get('/' => 'home');

    # API subrouter
    $r->mount('/api' => MyApp::API->to_app);

    # WebSocket echo
    $r->websocket('/ws/echo' => 'ws_echo');

    # SSE metrics
    $r->sse('/events/metrics' => 'sse_metrics');

    # Static files - find the root directory dynamically
    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..', 'public');
    $r->mount('/' => PAGI::App::File->new(root => $root)->to_app);
}

async sub home {
    my ($self, $req, $res) = @_;

    # Count HTTP requests
    $req->state->{metrics}{requests}++;

    # Access config via $req->state (populated by Lifespan startup)
    my $config = $req->state->{config};

    my $html = <<"HTML";
<!DOCTYPE html>
<html>
<head>
    <title>$config->{app_name}</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; }
        h1 { color: #333; }
        .section { background: #f5f5f5; border-radius: 8px; padding: 1rem; margin: 1rem 0; }
        .section h2 { margin-top: 0; color: #555; }
        input, button { padding: 0.5rem; font-size: 1rem; }
        button { background: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer; }
        button:hover { background: #0056b3; }
        button:disabled { background: #ccc; }
        #ws-log, #sse-log { background: #1e1e1e; color: #0f0; padding: 1rem; border-radius: 4px;
            height: 150px; overflow-y: auto; font-family: monospace; font-size: 0.9rem; }
        .status { padding: 0.25rem 0.5rem; border-radius: 4px; font-size: 0.8rem; }
        .connected { background: #28a745; color: white; }
        .disconnected { background: #dc3545; color: white; }
        a { color: #007bff; }
    </style>
</head>
<body>
    <h1>$config->{app_name}</h1>
    <p>Version: $config->{version} | Demonstrates PAGI::Endpoint::Router with HTTP, WebSocket, and SSE</p>

    <div class="section">
        <h2>REST API</h2>
        <p>
            <a href="/api/info">/api/info</a> - App information |
            <a href="/api/users">/api/users</a> - List users |
            <a href="/api/users/1">/api/users/1</a> - Get user by ID
        </p>
        <h3>Users <button id="refresh-users" style="font-size: 0.8rem;">Refresh</button></h3>
        <div id="users-list" style="background: #fff; padding: 0.5rem; border-radius: 4px; margin-bottom: 1rem;"></div>
        <h3>Create User</h3>
        <p>
            <input type="text" id="user-name" placeholder="Name" style="width: 150px;">
            <input type="email" id="user-email" placeholder="Email" style="width: 200px;">
            <button id="create-user">Create</button>
            <span id="create-status" style="margin-left: 0.5rem;"></span>
        </p>
    </div>

    <div class="section">
        <h2>WebSocket Echo <span id="ws-status" class="status disconnected">Disconnected</span></h2>
        <p>
            <input type="text" id="ws-input" placeholder="Type a message..." style="width: 300px;">
            <button id="ws-send">Send</button>
            <button id="ws-connect">Connect</button>
        </p>
        <div id="ws-log"></div>
    </div>

    <div class="section">
        <h2>SSE Metrics Stream <span id="sse-status" class="status disconnected">Disconnected</span></h2>
        <p>
            <button id="sse-connect">Connect</button>
            <button id="sse-disconnect" disabled>Disconnect</button>
            <span style="margin-left: 1rem;">Try disconnecting and reconnecting to see missed event count!</span>
        </p>
        <div id="sse-log"></div>
    </div>

    <script>
        // WebSocket Demo
        let ws = null;
        const wsLog = document.getElementById('ws-log');
        const wsStatus = document.getElementById('ws-status');
        const wsInput = document.getElementById('ws-input');
        const wsSend = document.getElementById('ws-send');
        const wsConnect = document.getElementById('ws-connect');

        function logWs(msg, type = 'info') {
            const color = type === 'sent' ? '#ff0' : type === 'recv' ? '#0f0' : '#888';
            wsLog.innerHTML += '<div style="color:' + color + '">' + new Date().toLocaleTimeString() + ' ' + msg + '</div>';
            wsLog.scrollTop = wsLog.scrollHeight;
        }

        wsConnect.onclick = () => {
            if (ws) { ws.close(); return; }
            ws = new WebSocket('ws://' + location.host + '/ws/echo');
            ws.onopen = () => {
                wsStatus.textContent = 'Connected';
                wsStatus.className = 'status connected';
                wsConnect.textContent = 'Disconnect';
                logWs('Connected to /ws/echo');
            };
            ws.onclose = () => {
                wsStatus.textContent = 'Disconnected';
                wsStatus.className = 'status disconnected';
                wsConnect.textContent = 'Connect';
                logWs('Disconnected');
                ws = null;
            };
            ws.onmessage = (e) => {
                const data = JSON.parse(e.data);
                logWs('Received: ' + JSON.stringify(data), 'recv');
            };
        };

        wsSend.onclick = () => {
            if (!ws || ws.readyState !== WebSocket.OPEN) { alert('Not connected!'); return; }
            const msg = wsInput.value || 'Hello!';
            ws.send(JSON.stringify({ text: msg, timestamp: Date.now() }));
            logWs('Sent: ' + msg, 'sent');
            wsInput.value = '';
        };

        wsInput.onkeypress = (e) => { if (e.key === 'Enter') wsSend.click(); };

        // SSE Demo
        let sse = null;
        const sseLog = document.getElementById('sse-log');
        const sseStatus = document.getElementById('sse-status');
        const sseConnect = document.getElementById('sse-connect');
        const sseDisconnect = document.getElementById('sse-disconnect');

        function logSse(msg, type = 'info') {
            const color = type === 'event' ? '#0ff' : type === 'reconnect' ? '#ff0' : '#0f0';
            sseLog.innerHTML += '<div style="color:' + color + '">' + new Date().toLocaleTimeString() + ' ' + msg + '</div>';
            sseLog.scrollTop = sseLog.scrollHeight;
        }

        sseConnect.onclick = () => {
            sse = new EventSource('/events/metrics');
            sseStatus.textContent = 'Connecting...';
            sseConnect.disabled = true;
            sseDisconnect.disabled = false;

            sse.addEventListener('connected', (e) => {
                sseStatus.textContent = 'Connected';
                sseStatus.className = 'status connected';
                logSse('Connected: ' + e.data, 'event');
            });

            sse.addEventListener('reconnected', (e) => {
                sseStatus.textContent = 'Reconnected';
                sseStatus.className = 'status connected';
                logSse('Reconnected: ' + e.data, 'reconnect');
            });

            sse.addEventListener('metrics', (e) => {
                const data = JSON.parse(e.data);
                logSse('Metrics: requests=' + data.requests + ' ws_active=' + data.ws_active + ' ws_msgs=' + (data.ws_messages || 0) + ' seq=' + data.sse_seq, 'event');
            });

            sse.onerror = () => {
                if (sse.readyState === EventSource.CLOSED) {
                    sseStatus.textContent = 'Disconnected';
                    sseStatus.className = 'status disconnected';
                    logSse('Connection closed');
                } else {
                    sseStatus.textContent = 'Reconnecting...';
                    logSse('Connection lost, reconnecting...');
                }
            };
        };

        sseDisconnect.onclick = () => {
            if (sse) { sse.close(); sse = null; }
            sseStatus.textContent = 'Disconnected';
            sseStatus.className = 'status disconnected';
            sseConnect.disabled = false;
            sseDisconnect.disabled = true;
            logSse('Manually disconnected');
        };

        // REST API Demo
        const usersList = document.getElementById('users-list');
        const refreshUsers = document.getElementById('refresh-users');
        const createUser = document.getElementById('create-user');
        const userName = document.getElementById('user-name');
        const userEmail = document.getElementById('user-email');
        const createStatus = document.getElementById('create-status');

        async function loadUsers() {
            try {
                const res = await fetch('/api/users');
                const users = await res.json();
                usersList.innerHTML = users.map(u =>
                    '<div style="padding: 0.25rem 0; border-bottom: 1px solid #eee;">' +
                    '<strong>' + u.name + '</strong> (' + u.email + ') - ID: ' + u.id + '</div>'
                ).join('');
            } catch (e) {
                usersList.innerHTML = '<em>Error loading users</em>';
            }
        }

        refreshUsers.onclick = loadUsers;

        createUser.onclick = async () => {
            const name = userName.value.trim();
            const email = userEmail.value.trim();
            if (!name || !email) {
                createStatus.textContent = 'Name and email required';
                createStatus.style.color = 'red';
                return;
            }
            try {
                const res = await fetch('/api/users', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name, email })
                });
                if (res.ok) {
                    const user = await res.json();
                    createStatus.textContent = 'Created user #' + user.id;
                    createStatus.style.color = 'green';
                    userName.value = '';
                    userEmail.value = '';
                    loadUsers();
                } else {
                    createStatus.textContent = 'Error: ' + res.status;
                    createStatus.style.color = 'red';
                }
            } catch (e) {
                createStatus.textContent = 'Error: ' + e.message;
                createStatus.style.color = 'red';
            }
        };

        // Load users on page load
        loadUsers();
    </script>
</body>
</html>
HTML

    await $res->html($html);
}

async sub ws_echo {
    my ($self, $ws) = @_;

    await $ws->accept;
    await $ws->keepalive(25);

    # Access metrics via $ws->state (populated by Lifespan startup)
    my $metrics = $ws->state->{metrics};
    $metrics->{requests}++;      # Count the WebSocket upgrade request
    $metrics->{ws_active}++;
    $metrics->{ws_messages} //= 0;

    $ws->on_close(sub {
        $metrics->{ws_active}--;
    });

    await $ws->send_json({ type => 'connected' });

    await $ws->each_json(async sub {
        my ($data) = @_;
        $metrics->{ws_messages}++;  # Count each message received
        await $ws->send_json({ type => 'echo', data => $data });
    });
}

async sub sse_metrics {
    my ($self, $sse) = @_;

    # Access metrics via $sse->state (populated by Lifespan startup)
    my $metrics = $sse->state->{metrics};

    # Track sequence number for reconnection detection
    # In production, you'd store this per-client or use timestamps
    $metrics->{sse_seq} //= 0;

    # Check if this is a reconnection (browser sends Last-Event-ID header)
    if (my $last_id = $sse->last_event_id) {
        my $missed = $metrics->{sse_seq} - $last_id;
        await $sse->send_event(
            event => 'reconnected',
            data  => {
                last_seen_id => $last_id,
                current_id   => $metrics->{sse_seq},
                missed       => $missed,
                message      => "Welcome back! You missed $missed updates.",
            },
            id    => $metrics->{sse_seq},
            retry => 3000,  # Reconnect after 3 seconds if disconnected
        );
    } else {
        await $sse->send_event(
            event => 'connected',
            data  => { status => 'ok', message => 'Fresh connection' },
            id    => $metrics->{sse_seq},
            retry => 3000,
        );
    }

    # Enable keepalive to prevent proxy timeouts
    await $sse->keepalive(15);

    # Log disconnect reason - useful for debugging connection issues
    $sse->on_close(sub {
        my ($sse, $reason) = @_;
        # In production, you might track this in metrics or logs
        warn "SSE client disconnected: $reason\n"
            unless $reason eq 'client_closed';  # Only log unexpected disconnects
    });

    # Send metrics every 2 seconds using loop-agnostic every()
    # Requires Future::IO to be installed
    await $sse->every(2, async sub {
        $metrics->{sse_seq}++;
        await $sse->send_event(
            event => 'metrics',
            data  => $metrics,
            id    => $metrics->{sse_seq},
        );
    });
}

1;
