defmodule TynDemo.Plug do
  @moduledoc "A trivial Plug with a distinct response, to prove Test A end-to-end."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.request_path do
      "/" -> send_resp(conn, 200, "Hello from a tyn-pack'd Mix release!\n")
      "/ping" -> send_resp(conn, 200, "pong from tyn_demo\n")
      _ -> send_resp(conn, 404, "not found\n")
    end
  end
end
