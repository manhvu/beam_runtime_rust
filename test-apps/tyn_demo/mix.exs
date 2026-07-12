defmodule TynDemo.MixProject do
  use Mix.Project

  # A minimal Bandit + Plug app — the SUPPORTED Tyn target (Track 1 Phase 2,
  # Test A). Its supervision tree owns the listener; `tyn-pack` emits
  # {apps,[tyn_demo]} and tyn_boot just starts the app.
  def project do
    [
      app: :tyn_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: true,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {TynDemo.Application, []}]
  end

  defp deps do
    [{:bandit, "~> 1.5"}, {:plug, "~> 1.16"}]
  end

  defp releases do
    # include_erts:false — Tyn uses its own musl beam.smp; tyn-pack ignores any
    # bundled ERTS anyway.
    [tyn_demo: [include_executables_for: [:unix], include_erts: false]]
  end
end
