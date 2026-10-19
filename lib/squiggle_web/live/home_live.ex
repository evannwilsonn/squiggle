defmodule SquiggleWeb.HomeLive do
  @moduledoc "The front page: start a room or join one by its code, and what the machine knows."
  use SquiggleWeb, :live_view

  alias Squiggle.Room

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Draw against the machine",
       eval: SquiggleWeb.Eval.get(),
       code: "",
       error: nil
     )}
  end

  @impl true
  def handle_event("new", _params, socket) do
    code = Room.new_code()
    :ok = Room.ensure(code)
    {:noreply, push_navigate(socket, to: ~p"/r/#{code}")}
  end

  def handle_event("join", %{"code" => code}, socket) do
    code = code |> String.upcase() |> String.replace(~r/[^A-Z]/, "")

    if String.length(code) == 4 do
      {:noreply, push_navigate(socket, to: ~p"/r/#{code}")}
    else
      {:noreply, assign(socket, code: code, error: "Room codes are four letters.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main class="sheet home">
        <SquiggleWeb.Marks.masthead />

        <section class="lede">
          <p class="hand big">Draw something. The machine is watching.</p>
          <p>
            A drawing game for one to eight people and one neural network. Whoever's turn it is
            draws a word. Everyone else races to guess it, and so does a network trained on
            Google's Quick, Draw! doodles. Play alone and it's just you and the machine.
          </p>
        </section>

        <section class="doors">
          <div class="door">
            <h2>New room</h2>
            <p>You get a four-letter code to share.</p>
            <button id="new-room" class="ink-btn" phx-click="new">Start a room</button>
          </div>
          <form id="join-form" class="door" phx-submit="join">
            <h2>Join a room</h2>
            <label for="code">Room code</label>
            <div class="row">
              <input
                id="code"
                name="code"
                value={@code}
                maxlength="4"
                autocomplete="off"
                placeholder="ABCD"
                class="code-in"
              />
              <button class="ink-btn ghost">Join</button>
            </div>
            <p :if={@error} class="err">{@error}</p>
          </form>
        </section>

        <section :if={@eval} class="knows">
          <h2>What the machine knows</h2>
          <p>
            It can only guess these {length(@eval["categories"])} things, so the drawer always gets one of them.
          </p>
          <ul class="words">
            <li :for={c <- @eval["categories"]}>
              <span>{c}</span>
              <small>{pct(@eval["per_class"][c])}</small>
            </li>
          </ul>
          <p class="fine">
            Each percentage is how often its first guess was right on 1,000 test doodles of that
            thing, none of which it saw in training. Overall: {pct(@eval["network"]["top1"])} first
            guess, {pct(@eval["network"]["top3"])} within its top three. Picking at random would get {pct(
              @eval["chance"]
            )}; matching each doodle to the average doodle of each thing gets {pct(
              @eval["nearest_mean"]
            )}.
          </p>
          <p :if={@eval["confusions"] != []} class="fine">
            What trips it up most:
            <span :for={c <- Enum.take(@eval["confusions"], 4)} class="mix">
              {c["drawn"]} read as {c["called"]} ({c["count"]})
            </span>
          </p>
        </section>

        <footer class="foot">
          Doodles from
          <a href="https://github.com/googlecreativelab/quickdraw-dataset">Quick, Draw!</a>
          (Google, CC BY 4.0). Built with Elixir, Phoenix LiveView, Nx and Axon.
        </footer>
      </main>
    </Layouts.app>
    """
  end

  defp pct(nil), do: "–"
  defp pct(x), do: "#{round(x * 100)}%"
end
