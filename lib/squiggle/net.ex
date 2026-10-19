defmodule Squiggle.Net do
  @moduledoc """
  The sketch recogniser: a small convolutional network built with Axon.

      28x28 sketch
      -> 3x3 conv, 32 filters -> 3x3 conv, 32 -> 2x2 max pool       (14x14)
      -> 3x3 conv, 64 filters -> 3x3 conv, 64 -> 2x2 max pool       (7x7)
      -> 256 units, dropout 0.4 -> 24 categories (softmax)

  About 0.9 million weights. Batch normalisation after each convolution keeps training steady
  at a high learning rate.
  """

  def model(classes \\ 24) do
    Axon.input("sketch", shape: {nil, 28, 28, 1})
    |> conv(32, "c1")
    |> conv(32, "c2")
    |> Axon.max_pool(kernel_size: 2, strides: 2)
    |> conv(64, "c3")
    |> conv(64, "c4")
    |> Axon.max_pool(kernel_size: 2, strides: 2)
    |> Axon.flatten()
    |> Axon.dense(256, activation: :relu, name: "fc")
    |> Axon.dropout(rate: 0.4)
    |> Axon.dense(classes, activation: :softmax, name: "out")
  end

  defp conv(x, filters, name) do
    x
    |> Axon.conv(filters, kernel_size: 3, padding: :same, name: name)
    |> Axon.batch_norm(name: name <> "_bn")
    |> Axon.relu()
  end
end
