defmodule Mix.Tasks.Squiggle.Averages do
  @shortdoc "Draws each category's average training doodle into priv/static/images/average/"
  @moduledoc """
      mix squiggle.averages

  Averages the 5,000 training doodles of each category into one 28 x 28 picture: the same
  averages the nearest-average baseline compares against. Each is saved as a transparent PNG
  whose opacity is the ink, so the page can colour it for light or dark mode. The PNG encoder is
  the few lines below (`:zlib` and `:erlang.crc32`), not a library.
  """
  use Mix.Task

  alias Squiggle.Sketches

  @scale 4

  @impl true
  def run(_args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:exla)
    Sketches.ensure_downloaded()
    dir = "priv/static/images/average"
    File.mkdir_p!(dir)

    for category <- Sketches.categories() do
      mean = category |> Sketches.load(5_000) |> Nx.mean(axes: [0]) |> Nx.reshape({28, 28})
      # Stretch so the darkest stroke is fully opaque.
      alpha =
        mean
        |> Nx.divide(Nx.reduce_max(mean))
        |> Nx.multiply(255)
        |> Nx.round()
        |> Nx.as_type(:u8)

      File.write!(Path.join(dir, category <> ".png"), png(Nx.to_list(alpha)))
    end

    Mix.shell().info("wrote #{length(Sketches.categories())} averages to #{dir}")
  end

  # Rows of 0..255 opacity values -> a PNG (8-bit grey + alpha, black ink), scaled up by @scale.
  defp png(rows) do
    size = length(rows) * @scale

    raw =
      for row <- rows, _ <- 1..@scale, into: <<>> do
        line = for a <- row, _ <- 1..@scale, into: <<>>, do: <<0, a>>
        <<0>> <> line
      end

    header = <<size::32, size::32, 8, 4, 0, 0, 0>>

    <<137, "PNG", 13, 10, 26, 10>> <>
      chunk("IHDR", header) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", "")
  end

  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>>
end
