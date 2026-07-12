import Config

# Minimal Phoenix Endpoint config. server: true so the release starts the HTTP
# listener; secret_key_base present so the Endpoint's signing path is exercised
# (that's the crypto dependency Test B is meant to surface).
config :phx_demo, PhxDemoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {0, 0, 0, 0}, port: 8080],
  server: true,
  secret_key_base: String.duplicate("abcdefgh", 8),
  render_errors: [formats: []]

config :logger, level: :info
