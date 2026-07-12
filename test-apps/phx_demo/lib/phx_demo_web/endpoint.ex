defmodule PhxDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :phx_demo

  # Trivial function plug as the endpoint body — enough to serve a response if
  # the Endpoint ever comes up. (On Tyn it is not expected to.)
  plug :hello

  def hello(conn, _opts) do
    Plug.Conn.send_resp(conn, 200, "Phoenix Endpoint on Tyn\n")
  end
end
