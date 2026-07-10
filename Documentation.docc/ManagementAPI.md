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

Returns installed PlayCover apps and their runtime status.

### App Status

```http
GET /apps/{bundleIdentifier}
```

Returns one installed app. The status includes:

- `bundleIdentifier`
- `name`
- `path`
- `running`
- `pid`
- `maaTools.enabled`
- `maaTools.port`
- `maaTools.reachable`

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
  "timeout": 15,
  "portTimeout": 15
}
```

This enables MaaTools for the app, optionally updates its MaaTools port,
and restarts the app by default so the injected PlayTools process opens the requested port.
Before changing settings, PlayCover returns `409` if another service occupies the
requested port. After a restart, PlayCover completes the MaaTools handshake, reads the
protocol version, and verifies the target bundle identifier. If verification times out,
the endpoint returns `504` with `maatools_port_unavailable` and restores the previous
saved MaaTools settings. `portTimeout` must be between 0.1 and 120 seconds.
When the port is changed without a restart, the new value is saved but a running app
continues listening on its previous MaaTools port until it is restarted.
