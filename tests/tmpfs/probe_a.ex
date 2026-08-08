defmodule ProbeA do
  # tmpfs validation probe. Prints machine-greppable PB_ lines the driver reads.
  # Byte-exact checks use == (value comparison) — NOT erlang:md5, which is
  # intermittently non-deterministic for large binaries on Tyn.

  defp p(l, v), do: IO.puts("PB " <> l <> ": " <> String.slice(inspect(v, charlists: :as_lists), 0, 200))

  defp attempt(f) do
    try do f.() rescue e -> {:rescue, Exception.message(e)} catch k, v -> {:catch, k, inspect(v)} end
  end

  def run_probe do
    Process.sleep(1500)
    IO.puts("PB_BEGIN")

    # (0) The first wall: System.tmp_dir must see /tmp as a writable directory.
    p("tmp_dir", System.tmp_dir())

    # (1) Volatile: /tmp must be empty at every boot.
    p("ls_empty_at_boot", attempt(fn -> File.ls!("/tmp") end))

    # (2) Small write -> read, byte-exact.
    small = :rand.bytes(1024)
    p("write_read_exact", attempt(fn ->
      :ok = File.write!("/tmp/small.bin", small)
      back = File.read!("/tmp/small.bin")
      _ = File.rm("/tmp/small.bin")
      back == small
    end))

    # (3) Large file (> one efile write buffer): 2 MiB, byte-exact readback.
    big = :rand.bytes(2 * 1024 * 1024)
    p("large_file_exact", attempt(fn ->
      :ok = File.write!("/tmp/large.bin", big)
      st = File.stat!("/tmp/large.bin")
      back = File.read!("/tmp/large.bin")
      _ = File.rm("/tmp/large.bin")
      {back == big, st.size}
    end))

    # (4) Upload pattern: write temp, then rename into place, read back exact.
    up = :rand.bytes(256 * 1024)
    p("rename_pattern", attempt(fn ->
      :ok = File.write!("/tmp/upload.tmp", up)
      :ok = File.rename!("/tmp/upload.tmp", "/tmp/final.bin")
      gone = not File.exists?("/tmp/upload.tmp")
      back = File.read!("/tmp/final.bin")
      _ = File.rm("/tmp/final.bin")
      {back == up, gone}
    end))

    # (5) mkdir + write into subdir + ls the subdir.
    p("mkdir_ls", attempt(fn ->
      :ok = File.mkdir!("/tmp/pbdir")
      :ok = File.write!("/tmp/pbdir/f.txt", "hi")
      ls = File.ls!("/tmp/pbdir")
      _ = File.rm("/tmp/pbdir/f.txt")
      _ = File.rmdir("/tmp/pbdir")
      ls
    end))

    # (6) rm removes the file (File.exists? -> false).
    p("rm_gone", attempt(fn ->
      :ok = File.write!("/tmp/rmme", "x")
      :ok = File.rm!("/tmp/rmme")
      File.exists?("/tmp/rmme")
    end))

    # (7) N concurrent hash-checked uploads, each a distinct file/content.
    p("concurrent_hash", attempt(fn ->
      n = 8
      results =
        1..n
        |> Enum.map(fn i ->
          Task.async(fn ->
            data = :rand.bytes(64 * 1024)
            path = "/tmp/conc_#{i}.bin"
            :ok = File.write!(path, data)
            back = File.read!(path)
            _ = File.rm(path)
            back == data
          end)
        end)
        |> Enum.map(&Task.await(&1, 15_000))
      "#{Enum.count(results, & &1)}/#{n}"
    end))

    # (8) ENOSPC: writing past the cap must return {:error,:enospc}, not crash.
    # Cap is 4 MiB; attempt 6 MiB. Clean up afterward to reclaim the cap.
    p("enospc_clean", attempt(fn ->
      r = File.write("/tmp/toobig.bin", :rand.bytes(6 * 1024 * 1024))
      _ = File.rm("/tmp/toobig.bin")
      r
    end))
    p("node_alive_after_enospc", Process.alive?(self()))

    IO.puts("PB_END node_alive=" <> inspect(Process.alive?(self())))
  end
end
