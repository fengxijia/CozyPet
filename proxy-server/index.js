// CozyPet proxy server.
//
// What it does
// ============
// - Accepts requests from the macOS app and forwards them to Anthropic / ElevenLabs.
// - Holds the *real* API keys server-side (env vars). Client only knows X-Client-Token.
// - Streams SSE through for Anthropic /v1/messages so the chat still types live.
// - Pipes binary audio through for ElevenLabs /v1/text-to-speech/:voiceId.
// - Per-IP rate-limit so a leaked client token can't drain the wallet overnight.
//
// Configuration
// =============
// Set in .env (or systemd EnvironmentFile=):
//   PORT                       (default 8080)
//   CLIENT_TOKEN               required — what the app sends in X-Client-Token
//   ANTHROPIC_API_KEY          required for /v1/messages
//   ELEVENLABS_API_KEY         required for /v1/text-to-speech, /v1/voices/add
//   ANTHROPIC_REQ_PER_MIN      default 30
//   ELEVENLABS_REQ_PER_MIN     default 20
//   ELEVENLABS_CHARS_PER_DAY   default 50000 (best-effort budget, in-memory)
//
// Endpoints
// =========
// POST /v1/messages                               → Anthropic
// POST /v1/text-to-speech/:voiceId                → ElevenLabs (audio/mpeg)
// POST /v1/voices/add                             → ElevenLabs (multipart)
// GET  /health                                    → 200 ok

import express from "express";
import morgan from "morgan";
import rateLimit from "express-rate-limit";
import { readFileSync } from "node:fs";

// Minimal .env loader so we don't need dotenv.
try {
  const env = readFileSync(new URL("./.env", import.meta.url), "utf8");
  for (const line of env.split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
    if (!m) continue;
    if (!process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
} catch { /* no .env file is fine when running under systemd */ }

const PORT = parseInt(process.env.PORT || "8080", 10);
const CLIENT_TOKEN = process.env.CLIENT_TOKEN;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY;
const ANTHROPIC_REQ_PER_MIN = parseInt(process.env.ANTHROPIC_REQ_PER_MIN || "30", 10);
const ELEVENLABS_REQ_PER_MIN = parseInt(process.env.ELEVENLABS_REQ_PER_MIN || "20", 10);
const ELEVENLABS_CHARS_PER_DAY = parseInt(process.env.ELEVENLABS_CHARS_PER_DAY || "50000", 10);

if (!CLIENT_TOKEN) {
  console.error("FATAL: CLIENT_TOKEN env var is required.");
  process.exit(1);
}

const app = express();
app.set("trust proxy", 1); // we sit behind Caddy/nginx; rate-limit needs the real IP
app.use(morgan("tiny"));

app.get("/health", (_req, res) => res.send("ok"));

// Token gate. The macOS app already sends a credential header that *would* be the
// real API key if it were talking to upstream directly:
//   - Anthropic route   → `x-api-key` (or `Authorization: Bearer ...` for authToken mode)
//   - ElevenLabs routes → `xi-api-key`
// We accept the shared client token via any of those, plus an explicit
// `X-Client-Token` for clients that prefer to be explicit. We never forward the
// header through — the real upstream key is swapped in below.
function requireClientToken(req, res, next) {
  const candidates = [
    req.get("x-client-token"),
    req.get("x-api-key"),
    req.get("xi-api-key"),
    (req.get("authorization") || "").replace(/^Bearer\s+/i, ""),
  ];
  if (!candidates.some((c) => c && c === CLIENT_TOKEN)) {
    return res.status(401).json({ error: "invalid_client_token" });
  }
  next();
}

const anthropicLimit = rateLimit({
  windowMs: 60_000,
  limit: ANTHROPIC_REQ_PER_MIN,
  standardHeaders: "draft-7",
  legacyHeaders: false,
  message: { error: "rate_limited", scope: "anthropic" },
});

const elevenlabsLimit = rateLimit({
  windowMs: 60_000,
  limit: ELEVENLABS_REQ_PER_MIN,
  standardHeaders: "draft-7",
  legacyHeaders: false,
  message: { error: "rate_limited", scope: "elevenlabs" },
});

// Cheap in-memory daily character budget for ElevenLabs (best-effort — restarts reset it).
// If you need persistence, swap for Redis. For a personal-scale friend distribution this is fine.
let ttsCharBudget = { day: todayKey(), used: 0 };
function todayKey() {
  return new Date().toISOString().slice(0, 10);
}
function consumeTtsChars(n) {
  const today = todayKey();
  if (ttsCharBudget.day !== today) ttsCharBudget = { day: today, used: 0 };
  if (ttsCharBudget.used + n > ELEVENLABS_CHARS_PER_DAY) return false;
  ttsCharBudget.used += n;
  return true;
}

// ─────────────────────────────────────────────────────────────────────
// Anthropic — /v1/messages, streaming SSE
// ─────────────────────────────────────────────────────────────────────
app.post(
  "/v1/messages",
  requireClientToken,
  anthropicLimit,
  express.raw({ type: "*/*", limit: "5mb" }),
  async (req, res) => {
    if (!ANTHROPIC_API_KEY) {
      return res.status(500).json({ error: "server_missing_anthropic_key" });
    }
    try {
      const upstream = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": ANTHROPIC_API_KEY,
          "anthropic-version": req.get("anthropic-version") || "2023-06-01",
        },
        body: req.body,
      });

      res.status(upstream.status);
      // Copy through a sensible subset of headers. Don't blindly copy `content-length`
      // because we may be streaming chunked; let express figure it out.
      const ct = upstream.headers.get("content-type");
      if (ct) res.setHeader("content-type", ct);
      const ce = upstream.headers.get("content-encoding");
      if (ce) res.setHeader("content-encoding", ce);

      if (!upstream.body) return res.end();

      // Stream body chunks through.
      const reader = upstream.body.getReader();
      req.on("close", () => reader.cancel().catch(() => {}));
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(value);
      }
      res.end();
    } catch (err) {
      console.error("anthropic proxy error:", err);
      if (!res.headersSent) res.status(502).json({ error: "upstream_error", detail: String(err) });
      else res.end();
    }
  }
);

// ─────────────────────────────────────────────────────────────────────
// ElevenLabs — /v1/text-to-speech/:voiceId  (returns audio/mpeg)
// ─────────────────────────────────────────────────────────────────────
app.post(
  "/v1/text-to-speech/:voiceId",
  requireClientToken,
  elevenlabsLimit,
  express.json({ limit: "200kb" }),
  async (req, res) => {
    if (!ELEVENLABS_API_KEY) {
      return res.status(500).json({ error: "server_missing_elevenlabs_key" });
    }
    const text = typeof req.body?.text === "string" ? req.body.text : "";
    if (!text) return res.status(400).json({ error: "missing_text" });
    if (!consumeTtsChars(text.length)) {
      return res.status(429).json({ error: "tts_daily_budget_exhausted" });
    }
    const voiceId = encodeURIComponent(req.params.voiceId);
    try {
      const upstream = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${voiceId}`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "xi-api-key": ELEVENLABS_API_KEY,
          accept: "audio/mpeg",
        },
        body: JSON.stringify(req.body),
      });
      res.status(upstream.status);
      const ct = upstream.headers.get("content-type");
      if (ct) res.setHeader("content-type", ct);
      if (!upstream.body) return res.end();
      const reader = upstream.body.getReader();
      req.on("close", () => reader.cancel().catch(() => {}));
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        res.write(value);
      }
      res.end();
    } catch (err) {
      console.error("elevenlabs tts proxy error:", err);
      if (!res.headersSent) res.status(502).json({ error: "upstream_error", detail: String(err) });
      else res.end();
    }
  }
);

// ─────────────────────────────────────────────────────────────────────
// ElevenLabs — /v1/voices/add  (multipart cloning; pass body through raw)
// Cloning costs real money so we cap separately and skip the JSON parser.
// ─────────────────────────────────────────────────────────────────────
const cloneLimit = rateLimit({
  windowMs: 60 * 60 * 1000, // 1h
  limit: 5,
  standardHeaders: "draft-7",
  legacyHeaders: false,
  message: { error: "rate_limited", scope: "voice_clone" },
});

app.post(
  "/v1/voices/add",
  requireClientToken,
  cloneLimit,
  express.raw({ type: "*/*", limit: "60mb" }),
  async (req, res) => {
    if (!ELEVENLABS_API_KEY) {
      return res.status(500).json({ error: "server_missing_elevenlabs_key" });
    }
    try {
      const upstream = await fetch("https://api.elevenlabs.io/v1/voices/add", {
        method: "POST",
        headers: {
          "content-type": req.get("content-type") || "multipart/form-data",
          "xi-api-key": ELEVENLABS_API_KEY,
          accept: "application/json",
        },
        body: req.body,
      });
      res.status(upstream.status);
      const ct = upstream.headers.get("content-type");
      if (ct) res.setHeader("content-type", ct);
      const buf = Buffer.from(await upstream.arrayBuffer());
      res.end(buf);
    } catch (err) {
      console.error("elevenlabs clone proxy error:", err);
      if (!res.headersSent) res.status(502).json({ error: "upstream_error", detail: String(err) });
      else res.end();
    }
  }
);

app.use((req, res) => res.status(404).json({ error: "not_found", path: req.path }));

app.listen(PORT, "127.0.0.1", () => {
  console.log(`cozypet-proxy listening on 127.0.0.1:${PORT}`);
  console.log(`  anthropic rpm=${ANTHROPIC_REQ_PER_MIN}  elevenlabs rpm=${ELEVENLABS_REQ_PER_MIN}  tts chars/day=${ELEVENLABS_CHARS_PER_DAY}`);
});
