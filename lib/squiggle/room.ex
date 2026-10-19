defmodule Squiggle.Room do
  @moduledoc """
  One game room, as a process. It holds the players, whose turn it is to draw, the secret word,
  the ink on the page and the chat, and it tells every player's LiveView about each change over
  PubSub.

  A round: the drawer gets a word the network knows and has a minute to draw it. Everyone else
  types guesses. The network watches the drawing too and calls out its own guesses, so the people
  guessing are racing the machine. Points:

    * a person who guesses right: 50, plus up to 100 more the sooner they get it
    * the machine, the same way, once its top guess is the word with at least 40% confidence
    * the drawer: 50 for each person, and for the machine, that gets it

  The round ends when time runs out or everyone (people and machine) has it. The word is shown
  for a few seconds, then the next player draws. Playing alone works: you draw, the machine
  guesses, and you score when it gets there.
  """
  use GenServer, restart: :transient

  alias Squiggle.Sketches

  @round_ms 60_000
  @reveal_ms 6_000
  @idle_ms 120_000
  @max_players 8
  @max_points 6_000
  @chat_keep 40
  @machine "machine"
  @confident 0.4

  def round_ms, do: @round_ms
  def machine_id, do: @machine

  # ── client ────────────────────────────────────────────────────────────

  @doc "A fresh room code: four consonants, easy to read out loud."
  def new_code, do: for(_ <- 1..4, into: "", do: <<Enum.random(~c"BCDFGHJKLMNPQRSTVWXZ")>>)

  def topic(code), do: "room:" <> code

  @doc "Starts the room unless it is already running."
  def ensure(code) do
    case DynamicSupervisor.start_child(Squiggle.Rooms, {__MODULE__, code}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  def start_link(code), do: GenServer.start_link(__MODULE__, code, name: via(code))
  defp via(code), do: {:via, Registry, {Squiggle.RoomRegistry, code}}

  @doc "Joins (or rejoins) the calling LiveView. Returns the room as it stands, ink included."
  def join(code, player, name), do: call(code, {:join, player, name, self()})

  def start(code), do: call(code, :start)
  def ink(code, player, stroke, points), do: call(code, {:ink, player, stroke, points})
  def undo(code, player), do: call(code, {:undo, player})
  def clear(code, player), do: call(code, {:clear, player})
  def guess(code, player, text), do: call(code, {:guess, player, text})
  def machine(code, player, guesses), do: call(code, {:machine, player, guesses})
  def state(code), do: call(code, :state)

  defp call(code, msg) do
    GenServer.call(via(code), msg)
  catch
    :exit, _ -> {:error, :gone}
  end

  # ── server ────────────────────────────────────────────────────────────

  @impl true
  def init(code) do
    state = %{
      code: code,
      players: %{},
      order: [],
      phase: :lobby,
      round: 0,
      drawer: nil,
      word: nil,
      recent: [],
      ends_at: nil,
      timer: nil,
      solved: MapSet.new(),
      strokes: %{},
      points: 0,
      chat: [],
      machine: %{score: 0, said: nil, top: []},
      idle: nil
    }

    {:ok, idle(state)}
  end

  @impl true
  def handle_call({:join, player, name, pid}, _from, s) do
    name = name |> to_string() |> String.trim() |> String.slice(0, 16)

    cond do
      name == "" ->
        {:reply, {:error, :name}, s}

      not Map.has_key?(s.players, player) and map_size(s.players) >= @max_players ->
        {:reply, {:error, :full}, s}

      true ->
        Process.monitor(pid)
        old = Map.get(s.players, player, %{score: 0, pids: []})
        s = put_in(s.players[player], %{name: name, score: old.score, pids: [pid | old.pids]})
        s = if player in s.order, do: s, else: %{s | order: s.order ++ [player]}
        s = if old.pids == [], do: note(s, :joined, name), else: s
        s = s |> cancel_idle() |> broadcast()
        {:reply, {:ok, public(s), s.strokes}, s}
    end
  end

  def handle_call(:start, _from, %{phase: :lobby, players: p} = s) when map_size(p) > 0,
    do: {:reply, :ok, next_round(s)}

  def handle_call({:ink, player, stroke, points}, _from, %{phase: :drawing, drawer: player} = s)
      when is_integer(stroke) and stroke >= 0 and stroke < 1_000 and is_list(points) do
    points = points |> Enum.filter(&is_integer/1) |> Enum.map(&min(max(&1, 0), 1000))
    points = Enum.take(points, 2 * max(@max_points - s.points, 0))

    if points == [] or rem(length(points), 2) == 1 do
      {:reply, :ok, s}
    else
      s = %{
        s
        | strokes: Map.update(s.strokes, stroke, points, &(&1 ++ points)),
          points: s.points + div(length(points), 2)
      }

      Phoenix.PubSub.broadcast(Squiggle.PubSub, topic(s.code), {:ink, player, stroke, points})
      {:reply, :ok, s}
    end
  end

  def handle_call({:undo, player}, _from, %{phase: :drawing, drawer: player} = s) do
    s =
      if s.strokes == %{},
        do: s,
        else: %{s | strokes: Map.delete(s.strokes, s.strokes |> Map.keys() |> Enum.max())}

    {:reply, :ok, redraw(s)}
  end

  def handle_call({:clear, player}, _from, %{phase: :drawing, drawer: player} = s),
    do: {:reply, :ok, redraw(%{s | strokes: %{}, points: 0})}

  def handle_call({:guess, player, text}, _from, s) do
    text = text |> to_string() |> String.trim() |> String.slice(0, 30)
    who = get_in(s.players, [player, :name])

    cond do
      text == "" or who == nil ->
        {:reply, :ok, s}

      s.phase == :drawing and player != s.drawer and not MapSet.member?(s.solved, player) and
          same?(text, s.word) ->
        {:reply, :correct, s |> solve(player, who) |> maybe_finish() |> broadcast()}

      true ->
        # The drawer, and people who already have it, can chat but never spell out the word.
        hide =
          s.phase == :drawing and (player == s.drawer or MapSet.member?(s.solved, player)) and
            String.contains?(normal(text), normal(s.word))

        {:reply, :ok,
         s |> say(%{kind: :guess, who: who, text: if(hide, do: "•••", else: text)}) |> broadcast()}
    end
  end

  def handle_call({:machine, player, guesses}, _from, %{phase: :drawing, drawer: player} = s) do
    top = Enum.take(guesses, 3)
    s = put_in(s.machine.top, top)

    s =
      case top do
        [{word, p} | _] when word == s.word and p >= @confident ->
          if MapSet.member?(s.solved, @machine), do: s, else: solve(s, @machine, "The machine")

        [{word, p} | _] when p >= 0.15 and word != s.machine.said and word != s.word ->
          s
          |> put_in([:machine, :said], word)
          |> say(%{kind: :machine, who: "The machine", text: "#{article(word)} #{word}?"})

        _ ->
          s
      end

    {:reply, :ok, s |> maybe_finish() |> broadcast()}
  end

  def handle_call(:state, _from, s), do: {:reply, public(s), s}

  # Anything else (ink from someone who isn't drawing, a start mid-round, ...) is ignored.
  def handle_call(_msg, _from, s), do: {:reply, :ok, s}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, s) do
    case Enum.find(s.players, fn {_, p} -> pid in p.pids end) do
      nil ->
        {:noreply, s}

      {id, p} ->
        pids = List.delete(p.pids, pid)

        s =
          if pids == [] do
            s =
              %{s | players: Map.delete(s.players, id), order: List.delete(s.order, id)}
              |> note(:left, p.name)

            if id == s.drawer and s.phase == :drawing,
              do: end_round(s, :drawer_left),
              else: maybe_finish(s)
          else
            put_in(s.players[id].pids, pids)
          end

        s = if s.players == %{}, do: idle(%{s | phase: :lobby, timer: cancel(s.timer)}), else: s
        {:noreply, broadcast(s)}
    end
  end

  def handle_info({:time_up, round}, %{round: round, phase: :drawing} = s),
    do: {:noreply, s |> end_round(:time) |> broadcast()}

  def handle_info({:next, round}, %{round: round, phase: :reveal} = s),
    do: {:noreply, next_round(s)}

  def handle_info(:idle, %{players: p} = s) when p == %{}, do: {:stop, :normal, s}
  def handle_info(_, s), do: {:noreply, s}

  # ── rounds ────────────────────────────────────────────────────────────

  defp next_round(%{order: []} = s), do: broadcast(%{s | phase: :lobby})

  defp next_round(s) do
    drawer = next_drawer(s)
    word = Enum.random(Sketches.categories() -- s.recent)
    round = s.round + 1
    now = System.system_time(:millisecond)

    %{
      s
      | phase: :drawing,
        round: round,
        drawer: drawer,
        word: word,
        recent: Enum.take([word | s.recent], 8),
        solved: MapSet.new(),
        strokes: %{},
        points: 0,
        ends_at: now + @round_ms,
        machine: %{s.machine | said: nil, top: []},
        timer: schedule({:time_up, round}, @round_ms, s.timer)
    }
    |> note(:drawing, s.players[drawer].name)
    |> redraw()
  end

  defp next_drawer(%{order: order, drawer: last}) do
    case Enum.find_index(order, &(&1 == last)) do
      nil -> hd(order)
      i -> Enum.at(order, rem(i + 1, length(order)))
    end
  end

  defp end_round(s, why) do
    s = %{
      s
      | phase: :reveal,
        ends_at: System.system_time(:millisecond) + @reveal_ms,
        timer: schedule({:next, s.round}, @reveal_ms, s.timer)
    }

    say(s, %{kind: :reveal, who: nil, text: s.word, why: why})
  end

  defp maybe_finish(%{phase: :drawing} = s) do
    everyone = [@machine | s.players |> Map.keys() |> List.delete(s.drawer)]
    if Enum.all?(everyone, &MapSet.member?(s.solved, &1)), do: end_round(s, :all), else: s
  end

  defp maybe_finish(s), do: s

  defp solve(s, who_id, who) do
    left = max(s.ends_at - System.system_time(:millisecond), 0) / @round_ms
    gain = 50 + round(100 * left)
    s = %{s | solved: MapSet.put(s.solved, who_id)}

    s =
      if who_id == @machine,
        do: update_in(s.machine.score, &(&1 + gain)),
        else: update_in(s.players[who_id].score, &(&1 + gain))

    s =
      if Map.has_key?(s.players, s.drawer),
        do: update_in(s.players[s.drawer].score, &(&1 + 50)),
        else: s

    say(s, %{kind: :correct, who: who, text: nil, gain: gain})
  end

  # ── helpers ───────────────────────────────────────────────────────────

  @doc "Whether a guess names the word: case, spacing, a leading article and a plural don't matter."
  def same?(guess, word), do: normal(guess) != "" and normal(guess) == normal(word)

  defp normal(text) do
    text
    |> String.downcase()
    |> String.replace(~r/^\s*(a|an|the)\s+/u, "")
    |> String.replace(~r/[^a-z]/u, "")
    |> String.replace_suffix("s", "")
  end

  defp article(word), do: if(String.first(word) in ~w(a e i o u), do: "an", else: "a")

  defp say(s, entry) do
    entry = Map.put(entry, :id, System.unique_integer([:positive, :monotonic]))
    %{s | chat: Enum.take([entry | s.chat], @chat_keep)}
  end

  defp note(s, kind, name), do: say(s, %{kind: kind, who: name, text: nil})

  defp redraw(s) do
    Phoenix.PubSub.broadcast(Squiggle.PubSub, topic(s.code), {:redraw, s.strokes})
    broadcast(s)
  end

  defp broadcast(s) do
    Phoenix.PubSub.broadcast(Squiggle.PubSub, topic(s.code), {:room, public(s)})
    s
  end

  @doc false
  def public(s) do
    %{
      code: s.code,
      phase: s.phase,
      round: s.round,
      drawer: s.drawer,
      word: s.word,
      ends_at: s.ends_at,
      solved: s.solved,
      chat: Enum.reverse(s.chat),
      machine: s.machine,
      players:
        s.order
        |> Enum.filter(&Map.has_key?(s.players, &1))
        |> Enum.map(fn id -> %{id: id, name: s.players[id].name, score: s.players[id].score} end)
    }
  end

  defp schedule(msg, ms, old) do
    cancel(old)
    Process.send_after(self(), msg, ms)
  end

  defp cancel(nil), do: nil

  defp cancel(ref) do
    Process.cancel_timer(ref)
    nil
  end

  defp idle(s), do: %{s | idle: Process.send_after(self(), :idle, @idle_ms)}
  defp cancel_idle(s), do: %{s | idle: cancel(s.idle)}
end
