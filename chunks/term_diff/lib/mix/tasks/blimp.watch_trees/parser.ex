defmodule Mix.Tasks.Blimp.WatchTrees.Parser do
  @moduledoc """
  Parses deciduous CLI table output into structured data.
  """

  @doc "Parse `deciduous nodes` table output into a list of node maps."
  @spec parse_nodes(String.t()) :: [map()]
  def parse_nodes(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&header_or_separator?/1)
    |> Enum.flat_map(&parse_node_line/1)
  end

  @doc "Parse `deciduous edges` table output into a list of edge maps."
  @spec parse_edges(String.t()) :: [map()]
  def parse_edges(output) do
    output
    |> String.split("\n")
    |> Enum.reject(&header_or_separator?/1)
    |> Enum.flat_map(&parse_edge_line/1)
  end

  @doc "Find root goal nodes (goals with no incoming edges)."
  @spec find_root_goals([map()], [map()]) :: [map()]
  def find_root_goals(nodes, edges) do
    targets = MapSet.new(edges, & &1.to)

    Enum.filter(nodes, fn n -> n.type == :goal and n.id not in targets end)
  end

  @doc "Extract file references from node titles matching `[files: ...]`."
  @spec extract_files([map()]) :: %{integer() => [String.t()]}
  def extract_files(nodes) do
    Enum.reduce(nodes, %{}, fn node, acc ->
      case Regex.run(~r/\[files:\s*([^\]]+)\]/, node.title) do
        [_, files_str] ->
          files = files_str |> String.split(",") |> Enum.map(&String.trim/1)
          Map.put(acc, node.id, files)

        nil ->
          acc
      end
    end)
  end

  @doc "Build a map of node_id => root_goal_id by traversing edges."
  @spec build_tree_membership([map()], [map()]) :: %{integer() => integer()}
  def build_tree_membership(nodes, edges) do
    parent_map =
      Enum.reduce(edges, %{}, fn edge, acc ->
        Map.put(acc, edge.to, edge.from)
      end)

    Enum.reduce(nodes, %{}, fn node, acc ->
      root = find_root(node.id, parent_map)
      Map.put(acc, node.id, root)
    end)
  end

  @doc "Detect files referenced by multiple goal trees."
  @spec detect_conflicts(%{integer() => [String.t()]}, %{integer() => integer()}) :: [map()]
  def detect_conflicts(file_map, tree_membership) do
    file_map
    |> Enum.flat_map(fn {node_id, files} ->
      tree_id = Map.get(tree_membership, node_id, node_id)
      Enum.map(files, fn file -> {file, tree_id} end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {file, tree_ids} ->
      unique = Enum.uniq(tree_ids)

      if length(unique) > 1 do
        [%{file: file, tree_ids: Enum.sort(unique)}]
      else
        []
      end
    end)
  end

  defp find_root(id, parent_map) do
    case Map.get(parent_map, id) do
      nil -> id
      parent_id -> find_root(parent_id, parent_map)
    end
  end

  defp header_or_separator?(line) do
    trimmed = String.trim(line)

    trimmed == "" or
      String.starts_with?(trimmed, "ID") or
      String.starts_with?(trimmed, "---") or
      Regex.match?(~r/^\d+ nodes:$/, trimmed)
  end

  defp parse_node_line(line) do
    case Regex.run(
           ~r/^\s*(\d+)\s+(goal|action|outcome|decision|option|observation)\s+(\w+)\s+(.+)$/,
           String.trim(line)
         ) do
      [_, id, type, status, title] ->
        [
          %{
            id: String.to_integer(id),
            type: String.to_atom(type),
            status: String.to_atom(status),
            title: String.trim(title)
          }
        ]

      nil ->
        []
    end
  end

  defp parse_edge_line(line) do
    case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\w+)\s+(.*)$/, String.trim(line)) do
      [_, id, from, to, type, rationale] ->
        [
          %{
            id: String.to_integer(id),
            from: String.to_integer(from),
            to: String.to_integer(to),
            type: String.to_atom(type),
            rationale: String.trim(rationale)
          }
        ]

      nil ->
        []
    end
  end
end
