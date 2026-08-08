defmodule ProbeA.UploadRouter do
  # Minimal Plug router exercising the REAL Plug.Upload multipart path on tmpfs.
  # The multipart parser writes the uploaded part to a temp file that
  # Plug.Upload.random_file!/1 creates in System.tmp_dir ("/tmp" on Tyn) — the
  # exact write-temp-then-hand-off-%Plug.Upload{} sequence the capability map
  # says tmpfs unblocks. The handler reads that temp file back and returns its
  # sha256 + size so the client can prove the bytes survived the round-trip.
  use Plug.Router

  plug Plug.Parsers, parsers: [:multipart], pass: ["*/*"], length: 100_000_000
  plug :match
  plug :dispatch

  # Discriminator: read the RAW request body (no multipart, no tmpfs) and return
  # its size + sha256. Isolates the inbound-socket/HTTP-body path from the
  # multipart parser and from tmpfs. POST with Content-Type: application/octet-stream.
  post "/raw" do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000, read_length: 1_000_000)
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    send_resp(conn, 200, "ok #{byte_size(body)} #{hash}")
  end

  post "/upload" do
    case conn.params["file"] do
      %Plug.Upload{path: path} ->
        data = File.read!(path)
        hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
        send_resp(conn, 200, "ok #{byte_size(data)} #{hash} tmp=#{path}")
      _ ->
        send_resp(conn, 400, "no file")
    end
  end

  get "/health" do
    send_resp(conn, 200, "up tmp=#{System.tmp_dir()}")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
