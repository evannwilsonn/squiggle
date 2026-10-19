defmodule Squiggle.RoomTest do
  use ExUnit.Case, async: true

  alias Squiggle.{Room, Sketches}

  setup do
    code = for _ <- 1..4, into: "", do: <<Enum.random(?A..?Z)>>
    :ok = Room.ensure(code)
    Phoenix.PubSub.subscribe(Squiggle.PubSub, Room.topic(code))
    %{code: code}
  end

  # A stand-in for a player's LiveView: joins from its own process and stays until told to stop.
  defp player(code, id, name) do
    test = self()

    pid =
      spawn(fn ->
        send(test, {:joined, id, Room.join(code, id, name)})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:joined, ^id, {:ok, _room, _strokes}}
    pid
  end

  defp start(code) do
    :ok = Room.start(code)
    assert_receive {:redraw, _}
    Room.state(code)
  end

  test "guesses match regardless of case, spacing, articles and plurals" do
    assert Room.same?("Cat", "cat")
    assert Room.same?("  an umbrella ", "umbrella")
    assert Room.same?("trees", "tree")
    assert Room.same?("Snow-man", "snowman")
    refute Room.same?("car", "cat")
    refute Room.same?("", "cat")
  end

  test "a round: the drawer gets a word, a right guess scores for both, the machine can win too",
       %{code: code} do
    player(code, "ada", "Ada")
    player(code, "bo", "Bo")
    room = start(code)
    assert room.phase == :drawing
    assert room.drawer == "ada"
    assert room.word in Sketches.categories()

    # A wrong guess goes to the chat.
    :ok = Room.guess(code, "bo", "definitely not it")
    assert Enum.any?(Room.state(code).chat, &(&1[:text] == "definitely not it"))

    # Bo gets it: the guess itself never reaches the chat, only that Bo got it.
    assert :correct = Room.guess(code, "bo", String.upcase(room.word))
    room = Room.state(code)
    assert room.phase == :drawing, "still waiting on the machine"
    [ada, bo] = Enum.sort_by(room.players, & &1.id)
    assert bo.score >= 50 and ada.score == 50

    refute Enum.any?(
             room.chat,
             &(&1[:kind] == :guess and String.downcase(&1[:text]) =~ room.word)
           )

    # A low-confidence machine guess doesn't count; a confident one ends the round.
    :ok = Room.machine(code, "ada", [{room.word, 0.2}])
    assert Room.state(code).phase == :drawing
    :ok = Room.machine(code, "ada", [{room.word, 0.9}, {"cat", 0.05}])
    room = Room.state(code)
    assert room.phase == :reveal
    assert room.machine.score >= 50
    assert Enum.find(room.players, &(&1.id == "ada")).score == 100
  end

  test "only the drawer can ink, clear or feed the machine; ink stays on the page", %{code: code} do
    player(code, "ada", "Ada")
    player(code, "bo", "Bo")
    room = start(code)

    :ok = Room.ink(code, "bo", 0, [10, 10, 20, 20])
    refute_receive {:ink, _, _, _}, 50

    :ok = Room.ink(code, "ada", 0, [10, 10, 2000, -5])
    assert_receive {:ink, "ada", 0, [10, 10, 1000, 0]}

    :ok = Room.machine(code, "bo", [{room.word, 0.99}])
    assert Room.state(code).phase == :drawing

    :ok = Room.clear(code, "bo")
    refute_receive {:redraw, _}, 50
    :ok = Room.clear(code, "ada")
    assert_receive {:redraw, strokes} when strokes == %{}
  end

  test "the drawer can't give the word away in the chat", %{code: code} do
    player(code, "ada", "Ada")
    player(code, "bo", "Bo")
    room = start(code)
    :ok = Room.guess(code, "ada", "it's a #{room.word}!!")
    assert List.last(Room.state(code).chat).text == "•••"
  end

  test "playing alone: the round ends when the machine gets it", %{code: code} do
    player(code, "solo", "Solo")
    room = start(code)
    :ok = Room.machine(code, "solo", [{room.word, 0.8}])
    room = Room.state(code)
    assert room.phase == :reveal
    assert [%{score: 50}] = room.players
  end

  test "names are required and trimmed; a drawer who leaves ends the round", %{code: code} do
    assert {:error, :name} = Room.join(code, "x", "   ")
    ada = player(code, "ada", "  Ada Lovelace the First  ")
    player(code, "bo", "Bo")
    assert Enum.any?(Room.state(code).players, &(&1.name == "Ada Lovelace the"))
    start(code)

    ref = Process.monitor(ada)
    send(ada, :stop)
    assert_receive {:DOWN, ^ref, :process, _, _}
    room = Room.state(code)
    assert room.phase == :reveal
    assert Enum.map(room.players, & &1.id) == ["bo"]
  end
end
