# Management API

Use the management API to inspect and control installed PlayCover apps from local or remote automation tools.

The server is disabled by default. Enable it in PlayCover preferences under Management.
The default listen address is `127.0.0.1` and the default port is `1718`.
Enabling or disabling the server takes effect immediately. Listen address, port,
and access key changes take effect after pressing Apply.
If the requested listen port is already in use, PlayCover keeps the current
listener running and shows an error in preferences.

## Access Control

The access key is optional. When it is empty, requests are unrestricted.

When a key is configured, pass it with one of these methods:

- `Authorization: Bearer <key>`
- `X-PlayCover-Key: <key>`
- `?key=<key>`

Prefer an HTTP header when accessing PlayCover over a network because query parameters
may be recorded by clients or proxies. The management protocol does not provide TLS;
only expose it on a trusted network or place it behind a trusted encrypted tunnel.

## Endpoints

All request and response bodies are JSON.

### Health

```http
GET /health
```

Returns whether the management server is running and the current listen endpoint.

### List Apps

```http
GET /apps
```

Returns `{"apps": [...]}` with installed PlayCover app summaries, sorted by
`bundleIdentifier`. Each summary contains:

- `bundleIdentifier`
- `name`
- `running`
- `pid` (or `null` when not running)
- `maaTools.enabled`
- `maaTools.port` (the configured port)

This endpoint does not connect to MaaTools, including for running apps. It omits
`maaTools.reachable`, `maaTools.version`, and `maaTools.bundleIdentifier`: no probe
was performed, which is different from a failed probe. Listing apps therefore
does not wait for MaaTools connection or handshake timeouts.

Use `GET /apps/{bundleIdentifier}` when verified MaaTools status is needed.
Clients must treat list entries as summaries, not complete app status objects.

### App Status

```http
GET /apps/{bundleIdentifier}
```

Returns one installed app. The status includes:

- `bundleIdentifier`
- `name`
- `running`
- `pid`
- `maaTools.enabled`
- `maaTools.port` (the configured MaaTools port, not a discovered listen port)
- `maaTools.reachable` (`true` only after a MaaTools handshake whose `BNDL` matches this app)
- `maaTools.version` (protocol version from `VERN`, or `null` if the handshake failed)
- `maaTools.bundleIdentifier` (bundle reported by `BNDL`, or `null` if the handshake failed)

`reachable` is not a raw TCP check. PlayCover probes only when this app is running
and MaaTools is enabled. A stopped app is not probed. A listener on the configured
port that is not MaaTools, or that belongs to a different bundle, returns
`reachable: false`. If the handshake succeeds for another bundle,
`maaTools.bundleIdentifier` is that other bundle.

Each MaaTools probe has one monotonic deadline, 2 seconds by default, shared by
TCP connection, all sends, the handshake acknowledgment, `VERN`, and the complete
`BNDL` response. Partial replies and interrupted I/O do not reset that budget.
Expiry closes the probe connection and is treated as a failed probe. This bounds
network waiting, not operating-system scheduling delays or the duration of a
whole launch/restart request, which can perform multiple probes.

### Start App

```http
POST /apps/{bundleIdentifier}/start
```

Optional body:

```json
{
  "timeout": 15
}
```

Starts the app if it is not already running.
PlayCover returns `200` only after the process is observed running and `504` if the
operation times out. Timeout values must be between 0.1 and 120 seconds.

### Stop App

```http
POST /apps/{bundleIdentifier}/stop
```

Optional body:

```json
{
  "force": false,
  "timeout": 10
}
```

Stops the app. If graceful termination times out, PlayCover force terminates it.
PlayCover returns `200` only after the process is observed stopped and `504` if both
termination attempts fail to stop it. Timeout values must be between 0.1 and 120 seconds.

### Restart App

```http
POST /apps/{bundleIdentifier}/restart
```

Runs the stop flow and then starts the app again.

### Open MaaTools

```http
POST /apps/{bundleIdentifier}/maatools/open
```

Optional body:

```json
{
  "port": 1717,
  "restart": true,
  "fresh": "off",
  "timeout": 15,
  "portTimeout": 15
}
```

This enables MaaTools for the app, optionally updates its MaaTools port,
and restarts the app by default so the injected PlayTools process opens the requested port.

`fresh` controls how the app is launched after a restart:

- `off` (default if omitted): normal launch
- `fallback`: try a normal launch first; retry with `open -F` only if no running
  process was observed or the process exited before MaaTools became ready
- `always`: launch with `open -F`

Before a fallback retry, PlayCover waits for the earlier process to be stopped
and its port to be closed. A still-running process whose MaaTools probe times
out, or a rejected launch request, does not trigger fallback.

`fresh` values other than `off` require `restart` to be `true` (the default).
`restart: false` with `fresh` set to `fallback` or `always` returns `400` with
`fresh_requires_restart`.

Before changing settings, PlayCover returns `409` with `maatools_port_in_use` if the
requested port is already occupied. Occupation is decided in this order:

1. Identify the listener with a MaaTools handshake (`VERN` + `BNDL`), without assuming
   the current app owns the port.
2. If that handshake reports a different bundle, return `409`. The response includes
   that bundle identifier and protocol version.
3. If the handshake cannot be completed, allow the request only when the target app is
   already running with MaaTools enabled on this same port (it may be a stuck target).
   Any other unidentified listener still returns `409`.

After a restart, PlayCover completes the MaaTools handshake, reads the
protocol version, and verifies the target bundle identifier. If verification times out,
the endpoint returns `504` with `maatools_port_unavailable` and restores the previous
saved MaaTools settings. `portTimeout` must be between 0.1 and 120 seconds.

For each launch attempt, `portTimeout` is a shared monotonic readiness budget,
covering probes, retry delays, and the existing one-second gap before the required
second successful handshake. Each probe is capped at both two seconds and the
remaining readiness budget. An insufficient window produces a timeout rather
than shortening the confirmation gap or starting more probes after expiry.
This readiness budget does not cover the entire open request, which also includes
shutdown, launch, and response status collection.

When the port is changed without a restart, the new value is saved but a running app
continues listening on its previous MaaTools port until it is restarted.
The response `maaTools` object uses the same handshake check as app status:
`reachable` is true only when the configured port answers as this app.
