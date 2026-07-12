defmodule PhxDemo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [PhxDemoWeb.Endpoint]
    Supervisor.start_link(children, strategy: :one_for_one, name: PhxDemo.Supervisor)
  end
end
