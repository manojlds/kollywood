defmodule Kollywood.Projects.Project do
  @moduledoc """
  Project record tracked by Kollywood.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @providers [:local, :github, :gitlab]

  @type t :: %__MODULE__{}

  schema "projects" do
    field(:name, :string)
    field(:slug, :string)
    field(:provider, Ecto.Enum, values: @providers)
    field(:repository, :string)
    field(:local_path, :string)
    field(:default_branch, :string, default: "main")
    field(:workflow_path, :string)
    field(:tracker_path, :string)
    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :name,
      :slug,
      :provider,
      :repository,
      :local_path,
      :default_branch,
      :workflow_path,
      :tracker_path,
      :enabled
    ])
    |> update_change(:name, &trim/1)
    |> update_change(:slug, &trim/1)
    |> update_change(:repository, &trim/1)
    |> update_change(:local_path, &trim/1)
    |> update_change(:default_branch, &trim/1)
    |> update_change(:workflow_path, &trim/1)
    |> update_change(:tracker_path, &trim/1)
    |> validate_required([:name, :slug, :provider, :default_branch])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:slug, min: 2, max: 80)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9\-_]*$/)
    |> validate_length(:default_branch, min: 1, max: 120)
    |> validate_provider_fields()
    |> unique_constraint(:slug)
  end

  defp validate_provider_fields(changeset) do
    case get_field(changeset, :provider) do
      :local ->
        changeset
        |> validate_required([:local_path])
        |> maybe_clear_field(:repository)

      provider when provider in [:github, :gitlab] ->
        changeset
        |> validate_required([:repository])
        |> maybe_clear_field(:local_path)

      _other ->
        changeset
    end
  end

  defp maybe_clear_field(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value when is_binary(value) ->
        if String.trim(value) == "" do
          put_change(changeset, field, nil)
        else
          changeset
        end

      _other ->
        changeset
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value
end
