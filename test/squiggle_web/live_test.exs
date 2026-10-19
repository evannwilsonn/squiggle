defmodule SquiggleWeb.LiveTest do
  use SquiggleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the front page starts a room", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#new-room")
    assert has_element?(view, "#join-form")

    assert {:error, {:live_redirect, %{to: "/r/" <> code}}} =
             view |> element("#new-room") |> render_click()

    assert code =~ ~r/^[A-Z]{4}$/
  end

  test "joining by code checks the code", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert view |> form("#join-form", code: "ab") |> render_submit() =~ "four letters"

    assert {:error, {:live_redirect, %{to: "/r/WXYZ"}}} =
             view |> form("#join-form", code: "wxyz") |> render_submit()
  end

  test "a new player picks a name, then sees the board", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/r/QQQQ")
    assert has_element?(view, "#name-form")
    view |> form("#name-form", name: "Ada") |> render_submit()
    assert has_element?(view, "#pad")
    assert has_element?(view, "#start")
  end

  test "a returning player with a saved name goes straight in, and can start and chat", %{
    conn: conn
  } do
    conn = put_connect_params(conn, %{"name" => "Bo", "player" => "abcdefgh1234"})
    {:ok, view, _html} = live(conn, ~p"/r/RRRR")
    assert has_element?(view, "#pad[data-drawer=false]")

    view |> element("#start") |> render_click()
    assert has_element?(view, "#pad[data-drawer=true]")
    assert has_element?(view, "#undo")

    view |> form("#guess-form", text: "hello") |> render_submit()
    assert has_element?(view, "#chat-log li", "Bo: hello")
  end

  test "the drawer's sketch reaches the machine, and its guesses show", %{conn: conn} do
    conn = put_connect_params(conn, %{"name" => "Cy", "player" => "zyxwvuts9876"})
    {:ok, view, _html} = live(conn, ~p"/r/SSSS")
    view |> element("#start") |> render_click()

    ring =
      for y <- 0..27, x <- 0..27, into: <<>> do
        <<if(abs(:math.sqrt((x - 13.5) ** 2 + (y - 13.5) ** 2) - 11) < 1.3, do: 255, else: 0)>>
      end

    render_hook(view, "look", %{"px" => Base.encode64(ring)})
    assert has_element?(view, ".bars li")
  end

  test "the page can be framed by Hugging Face", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert get_resp_header(conn, "x-frame-options") == []
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'self' https://huggingface.co"
  end
end
