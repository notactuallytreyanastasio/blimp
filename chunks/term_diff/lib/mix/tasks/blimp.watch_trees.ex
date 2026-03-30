defmodule Mix.Tasks.Blimp.WatchTrees do
  @moduledoc """
  Monitors parallel deciduous decision trees for overlapping file references.

  Polls `deciduous nodes` and `deciduous edges` periodically, identifies root
  goal trees, extracts file references, and warns about conflicts.

  ## Usage

      mix blimp.watch_trees [--interval 5000]
  """
  use Mix.Task

  alias Mix.Tasks.Blimp.WatchTrees.Parser

  @shortdoc "Watch deciduous trees for cross-agent file conflicts"

  @impl Mix.Task
  def run(args) do
    interval = parse_interval(args)
    Mix.shell().info("Watching deciduous trees (polling every #{interval}ms)...")
    loop(interval, %{})
  end

  defp parse_interval(args) do
    case OptionParser.parse(args, strict: [interval: :integer]) do
      {[interval: ms], _, _} -> ms
      _ -> 5_000
    end
  end

  defp loop(interval, prev_state) do
    state = poll()
    print_summary(state, prev_state)
    Process.sleep(interval)
    loop(interval, state)
  end

  defp poll do
    nodes_output = run_cmd("deciduous", ["nodes"])
    edges_output = run_cmd("deciduous", ["edges"])

    nodes = Parser.parse_nodes(nodes_output)
    edges = Parser.parse_edges(edges_output)
    root_goals = Parser.find_root_goals(nodes, edges)
    tree_membership = Parser.build_tree_membership(nodes, edges)
    file_map = Parser.extract_files(nodes)
    conflicts = Parser.detect_conflicts(file_map, tree_membership)

    %{
      nodes: nodes,
      edges: edges,
      root_goals: root_goals,
      tree_membership: tree_membership,
      file_map: file_map,
      conflicts: conflicts
    }
  end

  defp run_cmd(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, _} -> output
    end
  end

  defp print_summary(state, _prev_state) do
    Mix.shell().info("\n=== Deciduous Tree Watch ===")
    Mix.shell().info("Active goal trees: #{length(state.root_goals)}")

    for goal <- state.root_goals do
      Mix.shell().info("  [#{goal.id}] #{goal.title}")
    end

    if state.conflicts == [] do
      Mix.shell().info("No file conflicts detected.")
    else
      Mix.shell().info("\nCONFLICTS:")

      for conflict <- state.conflicts do
        tree_ids = Enum.join(conflict.tree_ids, ", ")
        Mix.shell().info("  #{conflict.file} -> trees [#{tree_ids}]")
      end

      Mix.shell().info("\nSuggested: Coordinate on conflicting files before merging.")
    end

    Mix.shell().info("============================\n")
  end
end
