defmodule Ampweb.Http do
  # Minimal raw-gen_tcp HTTP endpoint — Tyn's proven inbound path (commit
  # 458207a "Working HTTP echo via raw gen_tcp on OTP 27"), deliberately NOT
  # Bandit/Plug so the amplifier image stays zero-dep. One acceptor process, one
  # spawned handler per connection, blocking recv. Routes:
  #   GET /health -> "ok"                      (liveness = crash detector on Nitro)
  #   GET /chk    -> the amplifier counters    (large_md5 must stay 0)
  #   GET /       -> same as /chk
  # Binds 0.0.0.0 (IPv4) — Tyn's inet defaults can land on IPv6; be explicit.

  @default_port 8080

  def start_link do
    pid = spawn_link(fn -> listen() end)
    {:ok, pid}
  end

  defp port do
    case System.get_env("PORT") do
      nil -> @default_port
      s -> case Integer.parse(s) do
             {v, _} when v > 0 -> v
             _ -> @default_port
           end
    end
  end

  defp listen do
    opts = [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true},
            {:backlog, 128}, {:ip, {0, 0, 0, 0}}]
    case :gen_tcp.listen(port(), opts) do
      {:ok, lsock} ->
        IO.puts("AMPWEB_LISTEN port=#{port()}")
        accept_loop(lsock)

      {:error, reason} ->
        IO.puts("AMPWEB_LISTEN_FAIL reason=#{inspect(reason)}")
        Process.sleep(1000)
        listen()
    end
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn(fn -> handle(sock) end)
        accept_loop(lsock)

      {:error, _} ->
        accept_loop(lsock)
    end
  end

  defp handle(sock) do
    path =
      case :gen_tcp.recv(sock, 0, 5000) do
        {:ok, data} -> request_path(data)
        _ -> :none
      end

    body = route(path)
    resp =
      "HTTP/1.1 200 OK\r\n" <>
        "Content-Type: text/plain\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n" <>
        "Connection: close\r\n\r\n" <> body

    _ = :gen_tcp.send(sock, resp)
    :gen_tcp.close(sock)
  rescue
    _ -> (try do :gen_tcp.close(sock) rescue _ -> :ok end)
  end

  # Pull the path out of "GET /chk HTTP/1.1\r\n...".
  defp request_path(data) do
    line =
      data
      |> :binary.split("\r\n")
      |> hd()

    case String.split(line, " ") do
      [_method, p | _] -> p |> String.split("?") |> hd()
      _ -> :none
    end
  end

  defp route("/health"), do: "ok\n"
  defp route("/chk"), do: chk_body()
  defp route("/"), do: chk_body()
  defp route(_), do: chk_body()

  defp chk_body do
    Ampweb.Amp.snapshot()
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(" ")
    |> Kernel.<>("\n")
  end
end
