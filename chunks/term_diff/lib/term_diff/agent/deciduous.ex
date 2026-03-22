defmodule TermDiff.Agent.Deciduous do
  @moduledoc """
  Wrapper around the deciduous CLI for agent decision tree integration.

  Creates root goal nodes for agent runs and builds system prompt
  context with active agent info and decision tree instructions.
  """

  require Logger

  @doc """
  Create a root goal node for an agent run. Returns the node ID.
  """
  @spec create_root_node(String.t()) :: {:ok, integer()} | {:error, String.t()}
  def create_root_node(prompt) do
    truncated = String.slice(prompt, 0, 120)

    case System.cmd("deciduous", ["add", "goal", truncated, "-c", "80"], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/node (\d+)/, output) do
          [_, id_str] -> {:ok, String.to_integer(id_str)}
          _ -> {:error, "could not parse node ID from: #{output}"}
        end

      {output, _code} ->
        Logger.warning("deciduous add goal failed: #{output}")
        {:error, output}
    end
  end

  @doc """
  Query active goal nodes on the current branch.
  """
  @spec active_goals :: [%{id: integer(), title: String.t()}]
  def active_goals do
    case System.cmd("deciduous", ["nodes", "--branch", current_branch()], stderr_to_stdout: true) do
      {output, 0} -> parse_nodes(output)
      _ -> []
    end
  end

  @doc """
  Build the system prompt preamble for an agent, including its root node
  and info about other active agents.
  """
  @spec build_agent_preamble(integer(), integer(), String.t(), [map()]) :: String.t()
  def build_agent_preamble(run_id, root_node_id, _prompt, active_agents \\ []) do
    active_section =
      case active_agents do
        [] ->
          "No other agents currently active."

        agents ->
          agents
          |> Enum.map(fn a ->
            "  Run ##{a.id} (node ##{a.deciduous_root || "?"}): #{String.slice(a.prompt || "", 0, 80)}\n    Status: #{a.status}"
          end)
          |> Enum.join("\n")
      end

    """
    [BLIMP AGENT CONTEXT]

    You are Agent ##{run_id} working in the Blimp project.
    Your decision tree root is deciduous node ##{root_node_id}.

    Before starting work, log your first action:
      deciduous add action "Starting: <brief description>" -c 80
      deciduous link #{root_node_id} <new_node_id> -r "First step"

    While working:
      - Log actions BEFORE doing them: deciduous add action "..." -c N
      - Link to your root: deciduous link #{root_node_id} <node_id>
      - Log outcomes AFTER: deciduous add outcome "..." -c N

    When done:
      - Log a final outcome summarizing what you accomplished

    Active agents:
    #{active_section}

    [END BLIMP AGENT CONTEXT]
    """
  end

  defp current_branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> "main"
    end
  end

  defp parse_nodes(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case Regex.run(~r/^\s*(\d+)\s+(\w+)\s+\w+\s+(.+)$/, line) do
        [_, id, _type, title] ->
          %{id: String.to_integer(id), title: String.trim(title)}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
