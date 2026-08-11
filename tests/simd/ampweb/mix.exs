defmodule Ampweb.MixProject do
  use Mix.Project

  # Zero-dependency md5-preemption amplifier that reports over HTTP instead of
  # serial. Same corruption workload as tests/simd/ampapp (16 workers hashing a
  # known large binary under churn, counting transient mismatches), but run
  # CONTINUOUSLY with the running totals exposed on a raw-gen_tcp endpoint so it
  # is observable on Nitro — where Tyn's serial console does NOT reach the EC2
  # console. This is BUG-1's real-hardware-timing re-validation vehicle AND the
  # seed of the Phase-2 suite's Nitro HTTP reporting path (CLEAR_DECK Step 3).
  #
  # No :crypto / :ssl / Plug / Bandit — only core BIFs (:erlang.md5, binary.copy)
  # + :gen_tcp, so the image is minimal and isolates the kernel behaviour under
  # test from application dependencies (and from the crypto-NIF shim entirely).
  def project do
    [
      app: :ampweb,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [
      mod: {Ampweb.Application, []},
      extra_applications: [:logger]
    ]
  end
end
