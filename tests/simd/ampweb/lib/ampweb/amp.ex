defmodule Ampweb.Amp do
  # Continuous md5-preemption amplifier. Same measured workload as
  # tests/simd/ampapp/lib/ampapp/hash_amp.ex — each worker holds a reference
  # md5 of a known small (32 B) and large (64 KiB) binary, recomputes them in a
  # tight loop under binary-allocator churn, and counts GENUINE transient
  # mismatches (input intact + both recomputes now match the reference =>
  # the digest was momentarily wrong, i.e. BUG-1's red-zone clobber) — with the
  # same input/reference/recompute disambiguation so a corrupted input or a bad
  # reference is never miscounted as a transient.
  #
  # Differences from ampapp: runs forever (no deadline) and accumulates into a
  # shared ETS counter table (:ampstats) instead of collecting to a serial line,
  # so Ampweb.Http can report the running totals over HTTP on Nitro.
  #
  # Env: TYN_AMP_WORKERS (16), TYN_AMP_CHURN_KB (128), TYN_CHURN_TYPE (binary).

  @table :ampstats
  @keys [:iters, :small_md5, :large_md5, :input_corrupt, :ref_bad, :worker_exits]
  @small_bytes 32
  @large_kb 64
  @default_workers 16
  @default_churn_kb 128

  def table, do: @table
  def keys, do: @keys

  @doc "Create the shared counter table. Idempotent; call once before workers."
  def init_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        for k <- @keys, do: :ets.insert(@table, {k, 0})
        :ets.insert(@table, {:workers, workers()})
        :ok

      _ ->
        :ok
    end
  end

  @doc "Snapshot the counters as a keyword list (order = @keys ++ [:workers])."
  def snapshot do
    for k <- @keys ++ [:workers] do
      {k, (case :ets.lookup(@table, k) do
             [{^k, v}] -> v
             _ -> 0
           end)}
    end
  end

  def workers, do: env_int("TYN_AMP_WORKERS", @default_workers, 1)
  def churn_kb, do: env_int("TYN_AMP_CHURN_KB", @default_churn_kb, 0)
  def churn_type, do: System.get_env("TYN_CHURN_TYPE") || "binary"

  @doc "Start `n` amplifier workers under the given supervisor-less spawn_link."
  def start_worker(i) do
    spawn_link(fn -> worker(i) end)
  end

  defp worker(i) do
    ctype = churn_type()
    ckb = churn_kb()
    su = <<i, 0xC3, 0x3C, rem(i * 11, 256)>>
    small = :binary.copy(su, div(@small_bytes, 4))
    lu = <<i, 0x5A, 0xA5, rem(i * 7, 256)>>
    lreps = div(@large_kb * 1024, 4)
    large = :binary.copy(lu, lreps)
    creps = div(max(ckb, 1) * 1024, 4)

    r_small = :erlang.md5(small)
    r_large = :erlang.md5(large)
    loop(i, su, small, r_small, lu, lreps, large, r_large, creps, ctype)
  end

  # One ETS bump of :iters per iteration keeps /chk progress always visible
  # (the md5(64KiB)+churn work dominates a single counter increment by orders of
  # magnitude, so the leaf code the red zone lives in stays the hot preemption
  # target). Genuine mismatches — rare — are counted the moment they occur.
  defp loop(i, su, small, r_small, lu, lreps, large, r_large, creps, ctype) do
    if :erlang.md5(small) != r_small do
      if genuine(i, :SMALL, div(@small_bytes, 4), su, small, r_small) == 1, do: bump(:small_md5, 1)
    end

    if :erlang.md5(large) != r_large do
      if genuine(i, :LARGE, lreps, lu, large, r_large) == 1, do: bump(:large_md5, 1)
    end

    churn(ctype, lu, creps)
    bump(:iters, 1)

    loop(i, su, small, r_small, lu, lreps, large, r_large, creps, ctype)
  end

  defp churn("binary", lu, creps), do: (_ = :binary.copy(lu, creps); :ok)
  defp churn("heap", _lu, creps), do: (_ = heap_junk(div(max(creps, 1), 4), []); :ok)
  defp churn(_none, _lu, _creps), do: :ok

  defp heap_junk(0, acc), do: acc
  defp heap_junk(n, acc), do: heap_junk(n - 1, [rem(n, 256) | acc])

  # Disambiguate a raw md5 mismatch exactly as ampapp does: only a genuine
  # transient (input still intact, reference still valid) counts as 1.
  defp genuine(i, tag, reps, unit, bin, ref) do
    expected = :binary.copy(unit, reps)
    cond do
      bin != expected ->
        bump(:input_corrupt, 1)
        _ = tag
        _ = i
        0

      :erlang.md5(bin) == ref and :erlang.md5(expected) == ref ->
        1

      true ->
        bump(:ref_bad, 1)
        0
    end
  end

  defp bump(key, n) do
    :ets.update_counter(@table, key, n)
  rescue
    _ -> 0
  end

  defp env_int(name, default, min) do
    case System.get_env(name) do
      nil -> default
      s ->
        case Integer.parse(s) do
          {v, _} when v >= min -> v
          _ -> default
        end
    end
  end
end
