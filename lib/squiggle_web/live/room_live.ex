defmodule SquiggleWeb.RoomLive do
  @moduledoc """
  A player's view of a room. The drawer's browser streams its strokes here and, every half
  second while the drawing changes, a 28 x 28 copy of it for the network to guess at. Everyone
  else's browser gets the strokes as they arrive.
  """
  use SquiggleWeb, :live_view

  alias Squiggle.{Guesser, Room}

  @look_every_ms 250

  @impl true
  def mount(%{"code" => code}, _session, socket) do
    code = code |> String.upcase() |> String.replace(~r/[^A-Z]/, "") |> String.slice(0, 4)

    socket =
      assign(socket,
        code: code,
        page_title: "Room #{code}",
        room: nil,
        me: nil,
        error: nil,
        last_look: nil,
        guess_key: 0,
        flash_ok: false
      )

    cond do
      String.length(code) != 4 ->
        {:ok, push_navigate(socket, to: ~p"/")}

      connected?(socket) ->
        params = get_connect_params(socket) || %{}

        me =
          if is_binary(params["player"]) and params["player"] =~ ~r/^[a-z0-9]{8,32}$/,
            do: params["player"],
            else: random_id()

        :ok = Room.ensure(code)
        Phoenix.PubSub.subscribe(Squiggle.PubSub, Room.topic(code))
        {:ok, socket |> assign(me: me) |> join(params["name"])}

      true ->
        {:ok, socket}
    end
  end

  defp join(socket, name) when is_binary(name) and name != "" do
    case Room.join(socket.assigns.code, socket.assigns.me, name) do
      {:ok, room, strokes} ->
        socket
        |> assign(room: room, error: nil)
        |> push_event("redraw", %{strokes: strokes})
        |> push_event("remember", %{name: room_name(room, socket.assigns.me)})

      {:error, :full} ->
        assign(socket, error: "This room is full (8 players).")

      {:error, _} ->
        assign(socket, error: "Pick a name to play.")
    end
  end

  defp join(socket, _), do: socket

  defp room_name(room, me), do: Enum.find_value(room.players, "", &(&1.id == me && &1.name))
  defp random_id, do: :crypto.strong_rand_bytes(12) |> Base.encode32(case: :lower, padding: false)

  # ── events from this player's browser ──────────────────────────────────

  @impl true
  def handle_event("name", %{"name" => name}, socket), do: {:noreply, join(socket, name)}

  def handle_event("start", _, socket) do
    Room.start(socket.assigns.code)
    {:noreply, socket}
  end

  def handle_event("ink", %{"s" => stroke, "p" => points}, socket) do
    Room.ink(socket.assigns.code, socket.assigns.me, stroke, points)
    {:noreply, socket}
  end

  def handle_event("undo", _, socket) do
    Room.undo(socket.assigns.code, socket.assigns.me)
    {:noreply, socket}
  end

  def handle_event("clear", _, socket) do
    Room.clear(socket.assigns.code, socket.assigns.me)
    {:noreply, socket}
  end

  # The drawer's sketch, already squeezed to 28 x 28 the way Quick, Draw! doodles are.
  def handle_event("look", %{"px" => px}, socket) do
    now = System.monotonic_time(:millisecond)

    with true <- drawing?(socket.assigns),
         # monotonic time can be negative, so "never looked" is nil, not 0.
         true <-
           is_nil(socket.assigns.last_look) or now - socket.assigns.last_look >= @look_every_ms,
         {:ok, pixels} when byte_size(pixels) == 784 <- Base.decode64(px) do
      Room.machine(socket.assigns.code, socket.assigns.me, Guesser.guess(pixels, 3))
      {:noreply, assign(socket, last_look: now)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("guess", %{"text" => text}, socket) do
    result = Room.guess(socket.assigns.code, socket.assigns.me, text)

    {:noreply,
     assign(socket, guess_key: socket.assigns.guess_key + 1, flash_ok: result == :correct)}
  end

  # ── events from the room ───────────────────────────────────────────────

  @impl true
  def handle_info({:room, room}, socket), do: {:noreply, assign(socket, room: room)}

  def handle_info({:ink, from, stroke, points}, socket) do
    if from == socket.assigns.me,
      do: {:noreply, socket},
      else: {:noreply, push_event(socket, "ink", %{s: stroke, p: points})}
  end

  def handle_info({:redraw, strokes}, socket),
    do: {:noreply, push_event(socket, "redraw", %{strokes: strokes})}

  defp drawing?(%{room: %{phase: :drawing, drawer: d}, me: d}), do: true
  defp drawing?(_), do: false

  # ── view ───────────────────────────────────────────────────────────────

  @impl true
  def render(%{room: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main class="sheet room-gate">
        <SquiggleWeb.Marks.masthead code={@code} />
        <form :if={@me} id="name-form" class="door gate" phx-submit="name">
          <h2>Join room {@code}</h2>
          <label for="name">Your name</label>
          <div class="row">
            <input
              id="name"
              name="name"
              maxlength="16"
              autocomplete="nickname"
              required
              autofocus
              placeholder="e.g. Sam"
            />
            <button class="ink-btn">Play</button>
          </div>
          <p :if={@error} class="err">{@error}</p>
        </form>
        <p :if={!@me} class="hand big wait">Opening room {@code}…</p>
      </main>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        drawer?: assigns.room.drawer == assigns.me,
        solved?: MapSet.member?(assigns.room.solved, assigns.me),
        drawer_name:
          Enum.find_value(
            assigns.room.players,
            "someone",
            &(&1.id == assigns.room.drawer && &1.name)
          ),
        left_ms:
          if(assigns.room.ends_at,
            do: max(assigns.room.ends_at - System.system_time(:millisecond), 0),
            else: 0
          )
      )

    ~H"""
    <Layouts.app flash={@flash}>
      <main class={["sheet room", "phase-#{@room.phase}", @drawer? && "is-drawer"]}>
        <SquiggleWeb.Marks.masthead code={@code} />

        <section class="board">
          <div class="brief" id="brief">
            <%= case @room.phase do %>
              <% :lobby -> %>
                <p class="hand">Waiting to start.</p>
                <p class="sub">
                  Send friends the code <b class="mono">{@code}</b>
                  or this page's link. Or start now and draw for the machine alone.
                </p>
              <% :drawing -> %>
                <p :if={@drawer?} class="hand">
                  Draw <span class="secret">{article(@room.word)} {@room.word}</span>
                </p>
                <span
                  :if={@drawer?}
                  class="ghost-hint"
                  title={"The average of 5,000 people's #{@room.word}"}
                >
                  <span
                    class="avg"
                    style={"--img: url(/images/halftone/#{@room.word}.svg)"}
                    aria-hidden="true"
                  ></span>
                  <small>the average {@room.word}</small>
                </span>
                <p :if={!@drawer? and @solved?} class="hand">
                  You got it: <span class="secret">{@room.word}</span>
                </p>
                <p :if={!@drawer? and !@solved?} class="hand">
                  {@drawer_name} is drawing
                  <span class="blanks" aria-label={"#{String.length(@room.word)} letters"}>{blanks(
                    @room.word
                  )}</span>
                </p>
              <% :reveal -> %>
                <p class="hand">
                  It was <span class="secret">{article(@room.word)} {@room.word}</span>.
                </p>
            <% end %>
            <span
              :if={@room.phase != :lobby}
              id="clock"
              class="clock mono"
              phx-hook="Clock"
              data-left={@left_ms}
              data-key={"#{@room.round}-#{@room.phase}"}
            >
              {div(@left_ms, 1000)}
            </span>
          </div>

          <div
            id="pad"
            class="pad"
            phx-hook="Sketchpad"
            data-drawer={to_string(@drawer? and @room.phase == :drawing)}
            data-round={@room.round}
          >
            <div id="pad-ink" class="pad-ink" phx-update="ignore">
              <canvas aria-label="Drawing area"></canvas>
            </div>
            <span class="corner tl"></span><span class="corner tr"></span><span class="corner bl"></span><span class="corner br"></span>
          </div>

          <div :if={@room.phase == :lobby or (@drawer? and @room.phase == :drawing)} class="tools">
            <%= if @room.phase == :lobby do %>
              <button id="start" class="ink-btn" phx-click="start">Start the game</button>
            <% end %>
            <%= if @drawer? and @room.phase == :drawing do %>
              <button id="undo" class="ink-btn ghost" phx-click="undo">Undo</button>
              <button id="clear" class="ink-btn ghost" phx-click="clear">Clear</button>
            <% end %>
          </div>
        </section>

        <aside class="side">
          <section class="machine" aria-live="polite">
            <h2>The machine</h2>
            <%= if (@drawer? or @room.phase == :reveal) and @room.machine.top != [] do %>
              <ol class="bars">
                <li :for={{word, p} <- @room.machine.top} class={word == @room.word && "hit"}>
                  <span class="w">{word}</span>
                  <span class="bar"><i style={"width: #{round(p * 100)}%"}></i></span>
                  <span class="mono">{round(p * 100)}%</span>
                </li>
              </ol>
            <% else %>
              <p class="sub">
                <%= cond do %>
                  <% MapSet.member?(@room.solved, Room.machine_id()) -> %>
                    It has it.
                  <% @room.phase == :drawing -> %>
                    Watching the drawing…
                  <% true -> %>
                    Guesses as you draw. The drawer sees its top three.
                <% end %>
              </p>
            <% end %>
          </section>

          <section class="scores">
            <h2>Scores</h2>
            <ol>
              <li
                :for={p <- ranked(@room)}
                class={[p.id == @me && "me", p.id == Room.machine_id() && "bot"]}
              >
                <span class="who">
                  {p.name}
                  <em :if={p.id == @room.drawer and @room.phase == :drawing} class="tag">drawing</em>
                  <em
                    :if={MapSet.member?(@room.solved, p.id) and @room.phase == :drawing}
                    class="tag got"
                  >got it</em>
                </span>
                <span class="mono">{p.score}</span>
              </li>
            </ol>
          </section>

          <section class="chat">
            <ol id="chat-log" class="log" phx-hook="StickToBottom">
              <li :for={c <- @room.chat} id={"c-#{c.id}"} class={"k-#{c.kind}"}>{line(c)}</li>
            </ol>
            <form id="guess-form" phx-submit="guess" class={["guess", @flash_ok && "ok"]}>
              <input
                id={"guess-#{@guess_key}"}
                name="text"
                maxlength="30"
                autocomplete="off"
                placeholder={
                  if @drawer? or @solved? or @room.phase != :drawing, do: "Chat", else: "Type a guess"
                }
                phx-mounted={JS.focus()}
              />
              <button class="ink-btn">Send</button>
            </form>
          </section>
        </aside>
      </main>
    </Layouts.app>
    """
  end

  defp ranked(room) do
    bot = %{id: Room.machine_id(), name: "The machine", score: room.machine.score}
    Enum.sort_by([bot | room.players], &(-&1.score))
  end

  defp line(%{kind: :guess, who: w, text: t}), do: "#{w}: #{t}"
  defp line(%{kind: :machine, text: t}), do: "The machine: #{t}"
  defp line(%{kind: :correct, who: w, gain: g}), do: "#{w} got it! +#{g}"
  defp line(%{kind: :reveal, why: :drawer_left, text: t}), do: "The drawer left. It was #{t}."
  defp line(%{kind: :reveal, why: :time, text: t}), do: "Time's up. It was #{t}."
  defp line(%{kind: :reveal, text: t}), do: "Everyone got it: #{t}."
  defp line(%{kind: :joined, who: w}), do: "#{w} joined."
  defp line(%{kind: :left, who: w}), do: "#{w} left."
  defp line(%{kind: :drawing, who: w}), do: "#{w} is drawing."

  defp blanks(word), do: word |> String.graphemes() |> Enum.map_join(" ", fn _ -> "_" end)
  defp article(word), do: if(String.first(word) in ~w(a e i o u), do: "an", else: "a")
end
