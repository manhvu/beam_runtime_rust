defmodule TynDemo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "8080"))

    children = [
      {Bandit, plug: TynDemo.Plug, port: port, scheme: :http}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: TynDemo.Supervisor
    )
  end
end
