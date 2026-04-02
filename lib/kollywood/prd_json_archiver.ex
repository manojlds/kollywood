defmodule Kollywood.PrdJsonArchiver do
  @moduledoc """
  Periodically archives merged PRD stories (local tracker) older than 24 hours into
  `prd.archive.json` beside each project's `prd.json`.
  """

  use GenServer
  require Logger

  alias Kollywood.Projects
  alias Kollywood.Tracker.PrdJsonArchive

  @default_interval_ms 15 * 60 * 1000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def init(opts) do
    if enabled?() do
      interval_ms = Keyword.get(opts, :interval_ms) || interval_ms()
      send(self(), :tick)
      {:ok, %{interval_ms: interval_ms}}
    else
      {:ok, :disabled}
    end
  end

  def handle_info(:tick, %{interval_ms: interval_ms} = state) do
    run_archive_pass()
    schedule_tick(interval_ms)
    {:noreply, state}
  end

  def handle_info(:tick, :disabled), do: {:noreply, :disabled}

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp run_archive_pass do
    enabled_projects =
      Projects.list_enabled_projects()
      |> Enum.filter(&(Map.get(&1, :provider) == :local))

    Enum.each(enabled_projects, fn project ->
      path = Projects.tracker_path(project)

      if is_binary(path) and File.exists?(path) do
        case PrdJsonArchive.archive_stale_merged(path) do
          {:ok, 0} ->
            :ok

          {:ok, n} ->
            Logger.info(
              "PRD archive: moved #{n} merged stor(ies) to #{PrdJsonArchive.archive_path(path)}"
            )

          {:error, reason} ->
            Logger.warning("PRD archive failed for #{path}: #{reason}")
        end
      end
    end)
  end

  defp enabled? do
    Application.get_env(:kollywood, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  defp interval_ms do
    Application.get_env(:kollywood, __MODULE__, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end
end
