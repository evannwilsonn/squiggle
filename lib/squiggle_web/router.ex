defmodule SquiggleWeb.Router do
  use SquiggleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SquiggleWeb.Layouts, :root}
    plug :protect_from_forgery
    # Hugging Face shows a Space inside an iframe on huggingface.co, so allow that one framer.
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "frame-ancestors 'self' https://huggingface.co"
    }

    plug :allow_framing
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SquiggleWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/r/:code", RoomLive
  end

  defp allow_framing(conn, _opts), do: Plug.Conn.delete_resp_header(conn, "x-frame-options")

  # Other scopes may use custom stacks.
  # scope "/api", SquiggleWeb do
  #   pipe_through :api
  # end
end
