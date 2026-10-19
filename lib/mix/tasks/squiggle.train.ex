defmodule Mix.Tasks.Squiggle.Train do
  @shortdoc "Trains and evaluates the sketch network; writes priv/model and results/eval.json"
  @moduledoc """
      mix squiggle.train [--epochs 8]

  Compares the network against two floors on the same 24,000 held-out sketches:

    * guessing at random (1 in 24)
    * nearest average sketch: each category's mean drawing, and a sketch is called whichever
      mean it is closest to (written from scratch in Nx)
    * the convolutional network in `Squiggle.Net`

  The epoch that ships is the one with the best validation accuracy; the test set is scored
  once, at the end.
  """
  use Mix.Task

  alias Squiggle.{Net, Sketches}

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [epochs: :integer])
    epochs = Keyword.get(opts, :epochs, 8)
    Mix.Task.run("app.config")
    Application.ensure_all_started(:exla)
    Sketches.ensure_downloaded()

    %{train: {xtr, ytr}, valid: {xva, yva}, test: {xte, yte}} = Sketches.split()
    n = Nx.axis_size(xtr, 0)

    info(
      "#{n} training sketches, #{Nx.axis_size(xva, 0)} validation, #{Nx.axis_size(xte, 0)} test, #{length(Sketches.categories())} categories"
    )

    centroid_acc = accuracy(nearest_mean(xtr, ytr).(xte), yte)
    info("nearest average sketch: #{pct(centroid_acc)} on test")

    model = Net.model()
    {_init, predict} = Axon.build(model, compiler: EXLA, mode: :inference)

    probs = fn state, x ->
      x
      |> Nx.to_batched(1000)
      |> Enum.map(&predict.(state, %{"sketch" => &1}))
      |> Nx.concatenate()
    end

    loop =
      Axon.Loop.trainer(
        model,
        :categorical_cross_entropy,
        Polaris.Optimizers.adam(learning_rate: 1.0e-3),
        log: 0
      )

    {_state, curve, _key} =
      Enum.reduce(1..epochs, {Axon.ModelState.empty(), [], Nx.Random.key(7)}, fn epoch,
                                                                                 {state, curve,
                                                                                  key} ->
        t0 = System.monotonic_time(:second)
        {perm, key} = Nx.Random.shuffle(key, Nx.iota({n}))
        xs = Nx.take(xtr, perm)
        ys = ytr |> Nx.take(perm) |> one_hot()

        batches =
          Enum.zip(Nx.to_batched(xs, 128), Nx.to_batched(ys, 128))
          |> Enum.map(fn {a, b} -> {%{"sketch" => a}, b} end)

        state = Axon.Loop.run(loop, batches, state, epochs: 1, compiler: EXLA)
        acc = accuracy(argmax(probs.(state, xva)), yva)
        info("epoch #{epoch}: validation #{pct(acc)} (#{System.monotonic_time(:second) - t0}s)")
        {state, curve ++ [%{epoch: epoch, acc: acc, state: state}], key}
      end)

    best = Enum.max_by(curve, & &1.acc)
    info("shipping epoch #{best.epoch}")

    p = probs.(best.state, xte)
    top1 = accuracy(argmax(p), yte)
    top3 = top_k_accuracy(p, yte, 3)
    cats = Sketches.categories()
    pairs = Enum.zip(p |> argmax() |> Nx.to_flat_list(), Nx.to_flat_list(yte))

    per_class =
      pairs
      |> Enum.group_by(&elem(&1, 1))
      |> Map.new(fn {label, ps} ->
        {Enum.at(cats, label), Enum.count(ps, fn {a, b} -> a == b end) / length(ps)}
      end)

    confusions =
      pairs
      |> Enum.reject(fn {a, b} -> a == b end)
      |> Enum.frequencies_by(fn {a, b} -> {Enum.at(cats, b), Enum.at(cats, a)} end)
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.take(8)
      |> Enum.map(fn {{drawn, called}, count} ->
        %{drawn: drawn, called: called, count: count}
      end)

    File.mkdir_p!("priv/model")
    File.mkdir_p!("results")

    File.write!(
      "priv/model/net.nx",
      Nx.serialize(Nx.backend_copy(best.state.data, Nx.BinaryBackend))
    )

    eval = %{
      categories: cats,
      sketches: %{train: n, valid: Nx.axis_size(xva, 0), test: Nx.axis_size(xte, 0)},
      chance: 1 / length(cats),
      nearest_mean: centroid_acc,
      network: %{
        top1: top1,
        top3: top3,
        epoch: best.epoch,
        curve: Enum.map(curve, &%{epoch: &1.epoch, valid: &1.acc})
      },
      per_class: per_class,
      confusions: confusions
    }

    File.write!("results/eval.json", Jason.encode_to_iodata!(eval, pretty: true))
    File.cp!("results/eval.json", "priv/model/eval.json")
    info("network: #{pct(top1)} top-1, #{pct(top3)} top-3 on test")
  end

  # Each category's average sketch; a sketch is called whichever average it is nearest to.
  defp nearest_mean(x, y) do
    flat = Nx.reshape(x, {:auto, 784})
    onehot = one_hot(y)

    means =
      Nx.dot(Nx.transpose(onehot), flat)
      |> Nx.divide(onehot |> Nx.sum(axes: [0]) |> Nx.new_axis(1))

    sq = means |> Nx.pow(2) |> Nx.sum(axes: [1])

    fn xs ->
      f = Nx.reshape(xs, {:auto, 784})
      # Squared distance to each mean, minus |x|^2, which is the same for every mean.
      sq |> Nx.subtract(Nx.multiply(2, Nx.dot(f, Nx.transpose(means)))) |> Nx.argmin(axis: 1)
    end
  end

  defp one_hot(y),
    do:
      Nx.equal(Nx.new_axis(y, 1), Nx.iota({1, length(Sketches.categories())})) |> Nx.as_type(:f32)

  defp argmax(p), do: Nx.argmax(p, axis: 1)
  defp accuracy(pred, y), do: pred |> Nx.equal(y) |> Nx.mean() |> Nx.to_number()

  defp top_k_accuracy(p, y, k) do
    {_, idx} = Nx.top_k(p, k: k)
    idx |> Nx.equal(Nx.new_axis(y, 1)) |> Nx.any(axes: [1]) |> Nx.mean() |> Nx.to_number()
  end

  defp pct(x), do: "#{Float.round(x * 100, 1)}%"
  defp info(msg), do: Mix.shell().info(msg)
end
