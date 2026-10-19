defmodule SquiggleWeb.HomeLive do
  @moduledoc """
  The front page: a sheet that draws itself while the machine guesses in the margin, the doors
  into a room, and the 24 things the machine knows, each shown as the average of its 5,000
  training doodles.
  """
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

        <section class="hero">
          <div class="hero-copy">
            <p class="eyebrow">A drawing game · 1 to 8 people · 1 neural network</p>
            <h1 class="hand">Draw something.<br /><span>The machine is watching.</span></h1>
            <p class="lede">
              Whoever's turn it is draws a word. Everyone else races to guess it, and so does a
              network trained on Google's Quick, Draw! doodles, calling out its guesses in the
              margin as the lines go down. Play alone and it's you and the machine.
            </p>

            <div class="doors">
              <div class="door">
                <span class="tape" aria-hidden="true"></span>
                <h2 class="hand">New sheet</h2>
                <p>Get a four-letter code to share.</p>
                <button id="new-room" class="ink-btn" phx-click="new">Start a room</button>
              </div>
              <form id="join-form" class="door" phx-submit="join">
                <span class="tape" aria-hidden="true"></span>
                <h2 class="hand">Join a sheet</h2>
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
            </div>
          </div>

          <figure
            class="demo"
            aria-label="A house being drawn while the machine guesses: a box, then a tent, then a house."
          >
            <div class="demo-sheet">
              <span class="corner tl"></span><span class="corner tr"></span>
              <span class="corner bl"></span><span class="corner br"></span>
              <svg viewBox="0 0 200 200" aria-hidden="true">
                <path class="d-body" pathLength="1" d="M48 92 L48 168 L152 168 L152 92 Z" />
                <path class="d-roof" pathLength="1" d="M38 98 L100 42 L162 98" />
                <path class="d-door" pathLength="1" d="M88 168 L88 128 L112 128 L112 168" />
                <path class="d-window" pathLength="1" d="M124 110 L142 110 L142 128 L124 128 Z" />
              </svg>
              <span class="note n1">a box? <i>38%</i></span>
              <span class="note n2">a tent? <i>44%</i></span>
              <span class="note n3">a house! <i>97%</i></span>
              <svg class="loop" viewBox="0 0 120 60" aria-hidden="true">
                <path pathLength="1" d="M8 34 C 10 8, 104 6, 112 28 C 118 50, 22 58, 10 40" />
              </svg>
            </div>
            <figcaption>
              The drawer's browser shrinks the sketch to 28 × 28 pixels and sends it twice a second.
              Guesses come back in milliseconds.
            </figcaption>
          </figure>
        </section>

        <section :if={@eval} class="stats" aria-label="How often the machine is right">
          <div>
            <b class="mono">{pct1(@eval["network"]["top1"])}</b>
            <span>right on its first guess</span>
          </div>
          <div>
            <b class="mono">{pct1(@eval["network"]["top3"])}</b><span>right within three guesses</span>
          </div>
          <div class="dim">
            <b class="mono">{pct1(@eval["nearest_mean"])}</b><span>matching to the averages below</span>
          </div>
          <div class="dim">
            <b class="mono">{pct1(@eval["chance"])}</b><span>picking at random</span>
          </div>
          <p class="fine">On 24,000 doodles the network never saw in training.</p>
        </section>

        <section :if={@eval} class="knows">
          <div class="knows-head">
            <h2 class="hand">What the machine knows</h2>
            <p>
              Only these {length(@eval["categories"])} things, so the drawer always gets one of
              them. Each tile is the average of the 5,000 doodles of it the network learned from;
              the bar is how often it named that thing first on doodles it hadn't seen.
            </p>
          </div>
          <ul class="tiles">
            <li :for={c <- @eval["categories"]} class="tile">
              <span
                class="avg"
                style={"--img: url(#{avg(c)})"}
                aria-hidden="true"
              ></span>
              <span class="name hand">{c}</span>
              <span class="acc" aria-label={"#{pct(@eval["per_class"][c])} right"}>
                <i style={"width: #{round((@eval["per_class"][c] || 0) * 100)}%"}></i>
              </span>
              <small class="mono">{pct(@eval["per_class"][c])}</small>
            </li>
          </ul>

          <div :if={@eval["confusions"] != []} class="mixups">
            <h3 class="hand">What it mixes up</h3>
            <ul>
              <li :for={c <- Enum.take(@eval["confusions"], 4)}>
                <span
                  class="avg sm"
                  style={"--img: url(#{avg(c["drawn"])})"}
                  aria-hidden="true"
                ></span>
                <span class="arrow" aria-hidden="true">→</span>
                <span
                  class="avg sm"
                  style={"--img: url(#{avg(c["called"])})"}
                  aria-hidden="true"
                ></span>
                <span>
                  <b>{c["drawn"]}</b> read as <b>{c["called"]}</b>
                  <small class="mono">{c["count"]} times</small>
                </span>
              </li>
            </ul>
          </div>
        </section>

        <footer class="foot">
          <span>
            Doodles from
            <a href="https://github.com/googlecreativelab/quickdraw-dataset">Quick, Draw!</a>
            (Google, CC BY 4.0). Built with Elixir, Phoenix LiveView, Nx and Axon.
          </span>
          <a href="https://github.com/evannwilsonn/squiggle">Source</a>
        </footer>
      </main>
    </Layouts.app>
    """
  end

  defp avg(category), do: "/images/average/#{category}.png"

  defp pct(nil), do: "–"
  defp pct(x), do: "#{round(x * 100)}%"
  defp pct1(nil), do: "–"
  defp pct1(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 1)}%"
end
