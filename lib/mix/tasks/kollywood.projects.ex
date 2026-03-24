defmodule Mix.Tasks.Kollywood.Projects do
  @shortdoc "Manage onboarded Kollywood projects"

  @moduledoc """
  Manages project records stored in Kollywood's SQLite control store.

  ## Commands

      mix kollywood.projects list
      mix kollywood.projects add-local --name NAME --path PATH [--slug SLUG]
      mix kollywood.projects add-github --name NAME --repo OWNER/REPO [--slug SLUG]
      mix kollywood.projects add-gitlab --name NAME --repo GROUP/PROJECT [--slug SLUG]
  """

  use Mix.Task

  alias Kollywood.Projects

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      ["list" | rest] -> list_command(rest)
      ["add-local" | rest] -> add_local_command(rest)
      ["add-github" | rest] -> add_repo_command(:github, rest)
      ["add-gitlab" | rest] -> add_repo_command(:gitlab, rest)
      _other -> raise_usage_error()
    end
  end

  defp list_command(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: [], aliases: [])

    ensure_no_invalid_options!(invalid)
    ensure_no_positional_args!(positional)
    ensure_no_positional_args!(Keyword.keys(opts) |> Enum.map(&"--#{&1}"))

    projects = Projects.list_projects()

    if projects == [] do
      Mix.shell().info("No projects onboarded yet")
    else
      Mix.shell().info("Onboarded projects")

      Enum.each(projects, fn project ->
        source = project.local_path || project.repository || "-"

        Mix.shell().info(
          "- #{project.id} | #{project.slug} | provider=#{project.provider} | enabled=#{project.enabled} | source=#{source}"
        )
      end)
    end
  end

  defp add_local_command(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          path: :string,
          slug: :string,
          workflow_path: :string,
          tracker_path: :string,
          default_branch: :string,
          disabled: :boolean
        ]
      )

    ensure_no_invalid_options!(invalid)
    ensure_no_positional_args!(positional)

    name = required_option(opts, :name, "--name is required")
    path = required_option(opts, :path, "--path is required")

    attrs =
      %{
        name: name,
        provider: :local,
        local_path: Path.expand(path),
        default_branch: opts[:default_branch] || "main",
        enabled: not Keyword.get(opts, :disabled, false)
      }
      |> maybe_put(:slug, opts[:slug])
      |> maybe_put(:workflow_path, opts[:workflow_path])
      |> maybe_put(:tracker_path, opts[:tracker_path])

    create_project(attrs)
  end

  defp add_repo_command(provider, args) when provider in [:github, :gitlab] do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          name: :string,
          repo: :string,
          slug: :string,
          default_branch: :string,
          disabled: :boolean
        ]
      )

    ensure_no_invalid_options!(invalid)
    ensure_no_positional_args!(positional)

    name = required_option(opts, :name, "--name is required")
    repo = required_option(opts, :repo, "--repo is required")

    attrs =
      %{
        name: name,
        provider: provider,
        repository: repo,
        default_branch: opts[:default_branch] || "main",
        enabled: not Keyword.get(opts, :disabled, false)
      }
      |> maybe_put(:slug, opts[:slug])

    create_project(attrs)
  end

  defp create_project(attrs) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
        Mix.shell().info(
          "Added project #{project.slug} (provider=#{project.provider}, enabled=#{project.enabled})"
        )

      {:error, changeset} ->
        Mix.raise("Failed to add project: #{format_changeset_errors(changeset)}")
    end
  end

  defp maybe_put(attrs, _key, nil), do: attrs

  defp maybe_put(attrs, key, value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp required_option(opts, key, message) do
    case opts[key] do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          Mix.raise(message)
        else
          value
        end

      _other ->
        Mix.raise(message)
    end
  end

  defp ensure_no_invalid_options!([]), do: :ok

  defp ensure_no_invalid_options!(invalid) do
    values =
      invalid
      |> Enum.map(fn {key, value} ->
        if is_nil(value) do
          "--#{key}"
        else
          "--#{key}=#{value}"
        end
      end)

    Mix.raise("Unknown options: #{Enum.join(values, ", ")}")
  end

  defp ensure_no_positional_args!([]), do: :ok

  defp ensure_no_positional_args!(args) do
    Mix.raise("Unexpected positional arguments: #{Enum.join(args, " ")}")
  end

  defp format_changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {message, _opts}} -> "#{field} #{message}" end)
    |> Enum.join(", ")
  end

  defp raise_usage_error do
    Mix.raise("""
    Usage:
      mix kollywood.projects list
      mix kollywood.projects add-local --name NAME --path PATH [--slug SLUG] [--workflow-path PATH] [--tracker-path PATH] [--default-branch BRANCH] [--disabled]
      mix kollywood.projects add-github --name NAME --repo OWNER/REPO [--slug SLUG] [--default-branch BRANCH] [--disabled]
      mix kollywood.projects add-gitlab --name NAME --repo GROUP/PROJECT [--slug SLUG] [--default-branch BRANCH] [--disabled]
    """)
  end
end
