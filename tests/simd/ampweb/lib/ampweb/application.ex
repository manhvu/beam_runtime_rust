defmodule Ampweb.Application do
  use Application

  # Two children: the HTTP acceptor (raw gen_tcp, reports counters) and the
  # amplifier manager (owns the ETS table + worker pool). Order matters only
  # loosely — Ampweb.Amp.init_table/0 is idempotent and the manager creates the
  # table, so /chk returns zeros until the manager is up, never a crash.
  @impl true
  def start(_type, _args) do
    children = [
      %{id: Ampweb.Manager, start: {Ampweb.Manager, :start_link, []}, restart: :permanent},
      %{id: Ampweb.Http, start: {Ampweb.Http, :start_link, []}, restart: :permanent}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Ampweb.Supervisor)
  end
end
