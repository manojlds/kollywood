defmodule Kollywood.Chat.Store do
  @moduledoc false

  use GenServer

  alias Kollywood.Chat
  alias Kollywood.Chat.Session

  @type state :: %{
          sessions: %{optional(String.t()) => map()},
          by_project: %{optional(String.t()) => [String.t()]},
          by_ref: %{optional(reference()) => String.t()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @spec create_session(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def create_session(project_slug, cwd, opts \\ [])
      when is_binary(project_slug) and is_binary(cwd) and is_list(opts) do
    GenServer.call(__MODULE__, {:create_session, project_slug, cwd, opts})
  end

  @spec list_sessions(String.t()) :: [map()]
  def list_sessions(project_slug) when is_binary(project_slug) do
    GenServer.call(__MODULE__, {:list_sessions, project_slug})
  end

  @spec get_snapshot(String.t()) :: {:ok, map()} | {:error, String.t()}
  def get_snapshot(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:get_snapshot, session_id})
  end

  @spec send_prompt(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    GenServer.call(__MODULE__, {:send_prompt, session_id, prompt}, 120_000)
  end

  @spec cancel(String.t()) :: :ok | {:error, String.t()}
  def cancel(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:cancel, session_id})
  end

  @spec delete_session(String.t()) :: :ok | {:error, String.t()}
  def delete_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:delete_session, session_id})
  end

  @impl true
  def init(_state) do
    {:ok, %{sessions: %{}, by_project: %{}, by_ref: %{}}}
  end

  @impl true
  def handle_call({:create_session, project_slug, cwd, opts}, _from, state) do
    with :ok <- validate_non_empty(project_slug, "project slug is required"),
         :ok <- validate_non_empty(cwd, "cwd is required"),
         true <- File.dir?(cwd) or {:error, "chat cwd does not exist: #{cwd}"},
         {:ok, session_id} <- generate_session_id(),
         {:ok, pid} <- start_session_worker(session_id, project_slug, cwd, opts) do
      ref = Process.monitor(pid)
      inserted_at = DateTime.utc_now()

      entry = %{
        id: session_id,
        project_slug: project_slug,
        cwd: cwd,
        pid: pid,
        ref: ref,
        inserted_at: inserted_at
      }

      state =
        state
        |> put_session_entry(entry)
        |> put_ref(ref, session_id)

      publish(:chat_session_created, project_slug, session_id)

      {:reply, {:ok, session_view(entry)}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_sessions, project_slug}, _from, state) do
    sessions =
      state
      |> sessions_for_project(project_slug)
      |> Enum.map(&attach_summary/1)

    {:reply, sessions, state}
  end

  def handle_call({:get_snapshot, session_id}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, entry} ->
        {:reply, Session.snapshot(entry.pid), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:send_prompt, session_id, prompt}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, entry} ->
        {:reply, Session.send_prompt(entry.pid, prompt), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, session_id}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, entry} ->
        {:reply, Session.cancel(entry.pid), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, entry} ->
        Process.demonitor(entry.ref, [:flush])
        _ = DynamicSupervisor.terminate_child(Kollywood.Chat.SessionSupervisor, entry.pid)
        state = remove_session(state, session_id)
        publish(:chat_session_deleted, entry.project_slug, session_id)
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.by_ref, ref) do
      session_id when is_binary(session_id) ->
        project_slug =
          state
          |> Map.get(:sessions, %{})
          |> Map.get(session_id, %{})
          |> Map.get(:project_slug)

        state = remove_ref(state, ref) |> remove_session(session_id)

        if is_binary(project_slug) do
          publish(:chat_session_deleted, project_slug, session_id)
        end

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_session_worker(session_id, project_slug, cwd, opts) do
    child_spec =
      {Session,
       session_id: session_id,
       project_slug: project_slug,
       cwd: cwd,
       title: Keyword.get(opts, :title, "New chat")}

    case DynamicSupervisor.start_child(Kollywood.Chat.SessionSupervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, "failed to start chat session: #{inspect(reason)}"}
    end
  end

  defp validate_non_empty(value, message) when is_binary(value) do
    if String.trim(value) == "", do: {:error, message}, else: :ok
  end

  defp validate_non_empty(_value, message), do: {:error, message}

  defp generate_session_id do
    random = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, "chat-" <> random}
  end

  defp put_session_entry(state, entry) do
    project_ids =
      state
      |> Map.get(:by_project, %{})
      |> Map.get(entry.project_slug, [])

    by_project = Map.put(state.by_project, entry.project_slug, [entry.id | project_ids])
    sessions = Map.put(state.sessions, entry.id, entry)

    %{state | sessions: sessions, by_project: by_project}
  end

  defp put_ref(state, ref, session_id) do
    %{state | by_ref: Map.put(state.by_ref, ref, session_id)}
  end

  defp remove_ref(state, ref) do
    %{state | by_ref: Map.delete(state.by_ref, ref)}
  end

  defp remove_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{project_slug: project_slug} ->
        ids =
          state
          |> Map.get(:by_project, %{})
          |> Map.get(project_slug, [])
          |> Enum.reject(&(&1 == session_id))

        by_project =
          if ids == [] do
            Map.delete(state.by_project, project_slug)
          else
            Map.put(state.by_project, project_slug, ids)
          end

        sessions = Map.delete(state.sessions, session_id)

        %{state | sessions: sessions, by_project: by_project}

      _other ->
        state
    end
  end

  defp sessions_for_project(state, project_slug) do
    state
    |> Map.get(:by_project, %{})
    |> Map.get(project_slug, [])
    |> Enum.map(&Map.get(state.sessions, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil -> {:error, "chat session not found: #{session_id}"}
      entry -> {:ok, entry}
    end
  end

  defp attach_summary(entry) do
    summary =
      case Session.summary(entry.pid) do
        {:ok, value} -> value
        {:error, reason} -> %{status: :error, error: reason, title: "Chat session"}
      end

    session_view(entry)
    |> Map.merge(%{
      status: Map.get(summary, :status, :unknown),
      error: Map.get(summary, :error),
      title: Map.get(summary, :title, "Chat session"),
      updated_at: Map.get(summary, :updated_at)
    })
  end

  defp session_view(entry) do
    %{
      id: entry.id,
      project_slug: entry.project_slug,
      cwd: entry.cwd,
      inserted_at: entry.inserted_at
    }
  end

  defp publish(event, project_slug, session_id) do
    Phoenix.PubSub.broadcast(
      Kollywood.PubSub,
      Chat.topic(project_slug),
      {event, project_slug, session_id}
    )
  end
end
