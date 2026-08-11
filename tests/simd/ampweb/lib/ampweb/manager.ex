defmodule Ampweb.Manager do
  # Owns the ETS counter table and the pool of amplifier workers. Traps worker
  # exits: a worker that dies (an Elixir-level exception in the hash loop) is
  # counted as :worker_exits and respawned, so the amplifier keeps running and
  # the crash is observable in /chk. A node-level crash (e.g. BUG-1's naive-fix
  # "size_object: bad tag") kills the whole VM instead — observable as /health
  # going dark. Both failure modes are therefore visible over HTTP on Nitro.

  def start_link do
    pid = spawn_link(&init/0)
    {:ok, pid}
  end

  defp init do
    Process.flag(:trap_exit, true)
    Ampweb.Amp.init_table()
    n = Ampweb.Amp.workers()
    pids = for i <- 1..n, into: %{}, do: {Ampweb.Amp.start_worker(i), i}
    IO.puts("AMPWEB_BEGIN workers=#{n} churn_kb=#{Ampweb.Amp.churn_kb()} churn_type=#{Ampweb.Amp.churn_type()}")
    loop(pids)
  end

  defp loop(pids) do
    receive do
      {:EXIT, pid, _reason} ->
        pids =
          case Map.pop(pids, pid) do
            {nil, p} ->
              p

            {i, p} ->
              _ = bump_exit()
              Map.put(p, Ampweb.Amp.start_worker(i), i)
          end

        loop(pids)
    end
  end

  # Count a worker exit; never let a counter hiccup kill the manager.
  defp bump_exit do
    :ets.update_counter(Ampweb.Amp.table(), :worker_exits, 1)
  rescue
    _ -> 0
  end
end
