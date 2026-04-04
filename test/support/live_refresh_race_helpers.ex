defmodule KollywoodWeb.LiveRefreshRaceHelpers do
  import Phoenix.LiveViewTest

  def render_change_with_refresh_ticks(view, form_selector, params, refresh_ticks \\ 1)
      when is_integer(refresh_ticks) and refresh_ticks >= 0 do
    view
    |> form(form_selector)
    |> render_change(params)

    refresh_ticks(view, refresh_ticks)

    render(view)
  end

  def refresh_ticks(_view, 0), do: :ok

  def refresh_ticks(view, refresh_ticks) when is_integer(refresh_ticks) and refresh_ticks > 0 do
    Enum.each(1..refresh_ticks, fn _tick ->
      send(view.pid, :refresh)
      render(view)
    end)

    :ok
  end
end
