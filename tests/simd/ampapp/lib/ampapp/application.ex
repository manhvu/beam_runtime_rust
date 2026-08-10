defmodule Ampapp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      %{
        id: Ampapp.HashAmp,
        start: {Task, :start_link, [&Ampapp.HashAmp.run/0]},
        restart: :temporary
      }
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Ampapp.Supervisor)
  end
end
