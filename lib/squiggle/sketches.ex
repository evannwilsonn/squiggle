defmodule Squiggle.Sketches do
  @moduledoc """
  Google's Quick, Draw! dataset: millions of doodles people drew in under 20 seconds, released
  under CC BY 4.0. Each drawing comes as a 28 x 28 grayscale bitmap, centred and scaled to fill
  the frame, with white ink on black.

  Squiggle uses 24 categories that are quick to draw and look different from each other, and
  the first 7,000 drawings of each: 5,000 to train on, 1,000 to tune with, 1,000 to test.
  """

  @categories ~w(airplane apple banana bicycle car cat clock cloud envelope eye fish flower
                 guitar house key ladder moon pizza rainbow snowman star sun tree umbrella)

  @per_class 7_000
  @url "https://storage.googleapis.com/quickdraw_dataset/full/numpy_bitmap/"

  def categories, do: @categories
  def dir, do: Path.join(:code.priv_dir(:squiggle), "data")

  @doc "Downloads the first #{@per_class} drawings of each category (a byte range, not the whole file)."
  def ensure_downloaded do
    File.mkdir_p!(dir())

    for c <- @categories, path = Path.join(dir(), c <> ".npy"), not File.exists?(path) do
      {_, 0} =
        System.cmd("curl", [
          "-sSf",
          "-r",
          "0-#{128 + @per_class * 784 - 1}",
          "-o",
          path,
          @url <> c <> ".npy"
        ])
    end
  end

  @doc "A category's drawings as a `{n, 28, 28, 1}` tensor of floats in [0, 1]."
  def load(category, n \\ @per_class) do
    <<0x93, "NUMPY", _major, _minor, header_len::little-16, rest::binary>> =
      File.read!(Path.join(dir(), category <> ".npy"))

    <<_header::binary-size(header_len), pixels::binary>> = rest

    pixels
    |> binary_part(0, n * 784)
    |> Nx.from_binary(:u8)
    |> Nx.reshape({n, 28, 28, 1})
    |> Nx.divide(255)
  end

  @doc "Train / validation / test tensors and labels."
  def split do
    parts =
      @categories
      |> Enum.with_index()
      |> Enum.map(fn {c, label} ->
        x = load(c)
        {{x[0..4_999], label}, {x[5_000..5_999], label}, {x[6_000..6_999], label}}
      end)

    for i <- 0..2, into: %{} do
      chunk = Enum.map(parts, &elem(&1, i))
      x = chunk |> Enum.map(&elem(&1, 0)) |> Nx.concatenate()

      y =
        chunk
        |> Enum.flat_map(fn {xs, l} -> List.duplicate(l, Nx.axis_size(xs, 0)) end)
        |> Nx.tensor(type: :s64)

      {Enum.at([:train, :valid, :test], i), {x, y}}
    end
  end
end
