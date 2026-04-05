defmodule Kollywood.Chat do
  @moduledoc """
  Project-scoped ACP chat sessions.
  """

  alias Kollywood.Chat.Store

  @type session_id :: String.t()

  @spec create_session(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def create_session(project_slug, cwd, opts \\ [])
      when is_binary(project_slug) and is_binary(cwd) and is_list(opts) do
    Store.create_session(project_slug, cwd, opts)
  end

  @spec list_sessions(String.t()) :: [map()]
  def list_sessions(project_slug) when is_binary(project_slug) do
    Store.list_sessions(project_slug)
  end

  @spec get_snapshot(session_id()) :: {:ok, map()} | {:error, String.t()}
  def get_snapshot(session_id) when is_binary(session_id) do
    Store.get_snapshot(session_id)
  end

  @spec send_prompt(session_id(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def send_prompt(session_id, prompt) when is_binary(session_id) and is_binary(prompt) do
    Store.send_prompt(session_id, prompt)
  end

  @spec cancel(session_id()) :: :ok | {:error, String.t()}
  def cancel(session_id) when is_binary(session_id) do
    Store.cancel(session_id)
  end

  @spec delete_session(session_id()) :: :ok | {:error, String.t()}
  def delete_session(session_id) when is_binary(session_id) do
    Store.delete_session(session_id)
  end

  @spec topic(String.t()) :: String.t()
  def topic(project_slug) when is_binary(project_slug), do: "chat:project:" <> project_slug
end
