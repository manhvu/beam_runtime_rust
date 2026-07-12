defmodule PhxDemo.MixProject do
  use Mix.Project

  # A minimal full-Phoenix ENDPOINT app (not Router-as-plug) — Track 1 Phase 2,
  # Test B. Expected to FAIL on Tyn: the Endpoint's secret_key_base signing and
  # the bandit->thousand_island->ssl / plug->plug_crypto->crypto graph all need
  # :crypto, a NIF that is unavailable (beam.smp is static musl, no OpenSSL).
  def project do
    [
      app: :phx_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: true,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {PhxDemo.Application, []}]
  end

  defp deps do
    [{:phoenix, "~> 1.7"}, {:bandit, "~> 1.5"}]
  end

  defp releases do
    [phx_demo: [include_executables_for: [:unix], include_erts: false]]
  end
end
