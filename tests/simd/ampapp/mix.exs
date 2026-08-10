defmodule Ampapp.MixProject do
  use Mix.Project

  # Zero-dependency minimal app: the SIMD-preemption regression probe needs only
  # core BIFs (:erlang.md5, binary.copy, float arithmetic). No :crypto / :ssl /
  # Plug — deliberately, so the probe boots in the smallest possible image and
  # isolates the kernel behaviour under test from application dependencies.
  def project do
    [
      app: :ampapp,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [
      mod: {Ampapp.Application, []},
      extra_applications: [:logger]
    ]
  end
end
