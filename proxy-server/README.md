# cozypet-proxy

Thin Node/Express proxy that sits between the CozyPet macOS app and Anthropic /
ElevenLabs. Holds the real API keys server-side; the app only sends a shared
`X-Client-Token`. This is what lets you ship the app to friends without baking
your Anthropic key into the binary.

```
[ CozyPet.app ] --X-Client-Token--> [ Caddy HTTPS ] --> [ Node proxy ] --real key--> [ Anthropic / ElevenLabs ]
```

## What it accepts

| Method | Path                                  | Goes to                                              |
|--------|---------------------------------------|------------------------------------------------------|
| POST   | `/v1/messages`                        | Anthropic `/v1/messages` (streams SSE through)       |
| POST   | `/v1/text-to-speech/:voiceId`         | ElevenLabs TTS (returns `audio/mpeg`)                |
| POST   | `/v1/voices/add`                      | ElevenLabs voice cloning (multipart)                 |
| GET    | `/health`                             | `200 ok` — for uptime checks                         |

All billable routes require `X-Client-Token: <CLIENT_TOKEN>` and are per-IP rate
limited (defaults in `.env.example`). The TTS endpoint also enforces a daily
character budget so a leaked token can't drain the wallet overnight.

## Deploy on AWS (Ubuntu / Debian, ~10 minutes)

```sh
# 1. SSH to the box, install Node 20 + Caddy
sudo apt update
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs caddy

# 2. Drop the proxy somewhere stable
sudo mkdir -p /opt/cozypet-proxy
sudo useradd --system --home /opt/cozypet-proxy --shell /usr/sbin/nologin cozypet
# Copy the contents of this folder into /opt/cozypet-proxy/  (scp / git clone)
sudo chown -R cozypet:cozypet /opt/cozypet-proxy

cd /opt/cozypet-proxy
sudo -u cozypet npm install --omit=dev

# 3. Create .env (NEVER commit this)
sudo -u cozypet cp .env.example .env
sudo -u cozypet nano .env       # fill in CLIENT_TOKEN + the two upstream keys

# 4. systemd unit
sudo cp cozypet-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now cozypet-proxy
sudo systemctl status cozypet-proxy   # should be active (running)

# 5. HTTPS via Caddy
#    Make sure cozypet-proxy.example.com's A record points at this box first.
sudo cp Caddyfile /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile       # replace cozypet-proxy.example.com with your domain
sudo systemctl reload caddy

# 6. Open the AWS security group: inbound TCP 80 + 443 from 0.0.0.0/0. Port 8080 stays internal.

# 7. Smoke test
curl https://cozypet-proxy.example.com/health
# → ok
```

### Update flow

```sh
cd /opt/cozypet-proxy
sudo -u cozypet git pull           # if you cloned via git
sudo systemctl restart cozypet-proxy
```

### Rotating the client token

1. Edit `/opt/cozypet-proxy/.env`, change `CLIENT_TOKEN`.
2. `sudo systemctl restart cozypet-proxy`
3. Update `ProxyConfig.swift` in the macOS app, rebuild, ship a new Release.
4. Old installs will start getting 401 from the proxy — that's the lever for cutting off abuse.

## Local development

```sh
cd proxy-server
cp .env.example .env   # fill it in
npm install
npm start
# → cozypet-proxy listening on 127.0.0.1:8080
```

Point the dev macOS build at `http://127.0.0.1:8080` for both Anthropic base URL
and ElevenLabs base URL. (You'll need to set `NSAppTransportSecurity` for http
in `Info.plist` or stick to `https://localhost` via a local cert.)

## Cost / abuse caps

The defaults assume "share with a handful of friends":

| Knob                         | Default | Effect                                                 |
|------------------------------|---------|--------------------------------------------------------|
| `ANTHROPIC_REQ_PER_MIN`      | 30/IP   | ~one chat message every 2s sustained                   |
| `ELEVENLABS_REQ_PER_MIN`     | 20/IP   | Plenty for normal usage                                |
| `ELEVENLABS_CHARS_PER_DAY`   | 50000   | Global daily TTS budget (in-memory, resets on restart) |

Tighten in `.env` if your bill spikes. For real persistence + per-token quotas,
swap the in-memory budget for Redis.

## When to retire this

Once friends are happy paying for their own keys, set the proxy URL back to the
official endpoints in `ProxyConfig.swift` and leave the `X-Client-Token` blank
on their installs. The app already supports per-install keys via Settings.
