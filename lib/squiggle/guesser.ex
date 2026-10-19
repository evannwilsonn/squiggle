defmodule Squiggle.Guesser do
  @moduledoc """
  The trained sketch network behind a batching server: sketches from every player in every
  room queue up for a few milliseconds and run through the compiled network together.
  """

  alias Squiggle.{Net, Sketches}

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start:
        {Nx.Serving, :start_link, [[serving: serving(), name: __MODULE__, batch_timeout: 15]]}
    }
  end

  def model_path, do: Path.join(:code.priv_dir(:squiggle), "model/net.nx")

  def serving do
    params = model_path() |> File.read!() |> Nx.deserialize() |> Axon.ModelState.new()
    {_init, predict} = Axon.build(Net.model(), mode: :inference)

    Nx.Serving.new(
      fn opts ->
        run = Nx.Defn.jit(fn params, x -> predict.(params, %{"sketch" => x}) end, opts)
        fn batch -> run.(params, batch) end
      end,
      compiler: EXLA
    )
    |> Nx.Serving.batch_size(16)
    |> Nx.Serving.client_preprocessing(fn x -> {Nx.Batch.stack([x]), :ok} end)
    |> Nx.Serving.client_postprocessing(fn {probs, _meta}, :ok -> probs[0] end)
  end

  @doc """
  The network's top guesses for a 28 x 28 sketch given as 784 bytes (0 = paper, 255 = ink):
  `[{category, probability}]`, best first. A blank sketch gets no guesses.
  """
  @spec guess(binary(), pos_integer()) :: [{String.t(), float()}]
  def guess(pixels, k \\ 3) when byte_size(pixels) == 784 do
    if blank?(pixels) do
      []
    else
      x = pixels |> Nx.from_binary(:u8) |> Nx.reshape({28, 28, 1}) |> Nx.divide(255)
      probs = Nx.Serving.batched_run(__MODULE__, x)
      {p, idx} = Nx.top_k(probs, k: k)

      Enum.zip(
        Enum.map(Nx.to_flat_list(idx), &Enum.at(Sketches.categories(), &1)),
        Nx.to_flat_list(p)
      )
    end
  end

  @doc "Fewer than 8 inked pixels is not a drawing yet."
  def blank?(pixels), do: for(<<b <- pixels>>, b > 40, reduce: 0, do: (n -> n + 1)) < 8
end
