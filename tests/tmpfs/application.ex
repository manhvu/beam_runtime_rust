defmodule ProbeA.Application do
  use Application
  @impl true
  def start(_type, _args) do
    # No Repo — tmpfs probe needs no DB. Bandit serves the real multipart
    # upload endpoint (ProbeA.UploadRouter); the Task runs the syscall self-test.
    children = [
      {Bandit, plug: ProbeA.UploadRouter, scheme: :http, port: 8080},
      %{id: ProbeA.Probe, start: {Task, :start_link, [&ProbeA.run_probe/0]}, restart: :temporary}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: ProbeA.Supervisor)
  end
end
