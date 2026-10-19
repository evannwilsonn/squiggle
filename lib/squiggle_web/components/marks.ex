defmodule SquiggleWeb.Marks do
  @moduledoc "The masthead: a registration mark, the hand-lettered name and the light/dark switch."
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :code, :string, default: nil

  def masthead(assigns) do
    ~H"""
    <header class="masthead">
      <a href="/" class="brand" aria-label="Squiggle home">
        <svg class="reg" viewBox="0 0 40 40" aria-hidden="true">
          <circle cx="20" cy="20" r="11" />
          <path d="M20 2v36M2 20h36" />
        </svg>
        <span class="wordmark">Squiggle</span>
      </a>
      <span :if={@code} class="sheet-no">sheet <b>{@code}</b></span>
      <button
        class="theme"
        phx-click={JS.dispatch("phx:toggle-theme")}
        aria-label="Switch between light and dark"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="8" /><path d="M12 4a8 8 0 0 1 0 16z" /></svg>
      </button>
    </header>
    """
  end
end
