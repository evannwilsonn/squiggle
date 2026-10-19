defmodule SquiggleWeb.Eval do
  @moduledoc "The training run's evaluation (priv/model/eval.json), read once and kept in memory."

  def get do
    case :persistent_term.get(__MODULE__, :unset) do
      :unset ->
        eval = read()
        :persistent_term.put(__MODULE__, eval)
        eval

      eval ->
        eval
    end
  end

  defp read do
    with {:ok, body} <- File.read(Path.join(:code.priv_dir(:squiggle), "model/eval.json")),
         {:ok, eval} <- Jason.decode(body) do
      eval
    else
      _ -> nil
    end
  end
end
