import Foundation

// Default endpoints baked into the macOS app so end-users don't need their own
// API keys — every request goes through the proxy in `proxy-server/`.
//
// To set up your own deployment:
//   1. Copy this file to ProxyConfig.swift (gitignored).
//   2. Fill in `proxyBaseURL` with your https://... domain.
//   3. Fill in `clientToken` with the same value as CLIENT_TOKEN in proxy-server/.env.
//   4. Rebuild the app.
//
// If `clientToken` is empty, the SettingsView defaults fall back to blank fields —
// users will need to paste their own Anthropic / ElevenLabs keys, like the v0
// build did.

enum ProxyConfig {
    /// Anthropic-style base; the app appends `/v1/messages`.
    static let anthropicBaseURL = "https://cozypet-proxy.example.com"

    /// ElevenLabs-style base; the app appends `/v1/text-to-speech/<voice>` etc.
    static let elevenlabsBaseURL = "https://cozypet-proxy.example.com"

    /// Shared token the proxy validates. Long random string. Rotate by editing
    /// `proxy-server/.env`, restarting the service, and shipping a new app release.
    static let clientToken = ""

    /// A neutral voice id we ship for first-launch ergonomics. Users can change
    /// it in Settings → 语音, or clone their own.
    static let defaultVoiceID = ""

    /// If the user has never configured anything, should we pre-fill the proxy
    /// defaults? Set to false to ship a "BYO key" build instead.
    static let prefillProxyOnFirstLaunch = true
}
