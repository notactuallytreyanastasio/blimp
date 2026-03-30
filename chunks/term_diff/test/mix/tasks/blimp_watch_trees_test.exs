defmodule Mix.Tasks.Blimp.WatchTreesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Blimp.WatchTrees.Parser

  describe "parse_nodes/1" do
    test "parses deciduous nodes table output" do
      output = """
      134 nodes:
      ID    TYPE         STATUS     TITLE
      ----------------------------------------------------------------------
      121   goal         pending    Implement WebSocket reconnection
      122   action       pending    Add heartbeat to WS connection
      123   outcome      pending    Heartbeat working in dev
      """

      assert Parser.parse_nodes(output) == [
               %{
                 id: 121,
                 type: :goal,
                 status: :pending,
                 title: "Implement WebSocket reconnection"
               },
               %{
                 id: 122,
                 type: :action,
                 status: :pending,
                 title: "Add heartbeat to WS connection"
               },
               %{id: 123, type: :outcome, status: :pending, title: "Heartbeat working in dev"}
             ]
    end

    test "returns empty list for empty output" do
      assert Parser.parse_nodes("") == []
    end

    test "handles nodes with file references in title" do
      output = """
      2 nodes:
      ID    TYPE         STATUS     TITLE
      ----------------------------------------------------------------------
      10    goal         pending    Fix parser [files: lib/parser.ex,lib/lexer.ex]
      """

      [node] = Parser.parse_nodes(output)
      assert node.id == 10
      assert node.title == "Fix parser [files: lib/parser.ex,lib/lexer.ex]"
    end
  end

  describe "parse_edges/1" do
    test "parses deciduous edges table output" do
      output = """
      ID    FROM   TO     TYPE         RATIONALE
      ----------------------------------------------------------------------
      1     121    122    leads_to     Implementation step
      2     122    123    leads_to     Result of action
      """

      assert Parser.parse_edges(output) == [
               %{id: 1, from: 121, to: 122, type: :leads_to, rationale: "Implementation step"},
               %{id: 2, from: 122, to: 123, type: :leads_to, rationale: "Result of action"}
             ]
    end

    test "returns empty list for empty output" do
      assert Parser.parse_edges("") == []
    end
  end

  describe "find_root_goals/2" do
    test "identifies root goal nodes (goals with no incoming edges)" do
      nodes = [
        %{id: 1, type: :goal, status: :pending, title: "Root goal"},
        %{id: 2, type: :action, status: :pending, title: "An action"},
        %{id: 3, type: :goal, status: :pending, title: "Child goal"}
      ]

      edges = [
        %{id: 1, from: 1, to: 2, type: :leads_to, rationale: ""},
        %{id: 2, from: 1, to: 3, type: :leads_to, rationale: ""}
      ]

      roots = Parser.find_root_goals(nodes, edges)
      assert length(roots) == 1
      assert hd(roots).id == 1
    end
  end

  describe "extract_files/1" do
    test "extracts file references from node titles" do
      nodes = [
        %{
          id: 1,
          type: :goal,
          status: :pending,
          title: "Fix parser [files: lib/parser.ex,lib/lexer.ex]"
        },
        %{id: 2, type: :action, status: :pending, title: "No files here"}
      ]

      file_map = Parser.extract_files(nodes)
      assert file_map == %{1 => ["lib/parser.ex", "lib/lexer.ex"]}
    end

    test "returns empty map when no files" do
      nodes = [%{id: 1, type: :goal, status: :pending, title: "No files"}]
      assert Parser.extract_files(nodes) == %{}
    end
  end

  describe "detect_conflicts/2" do
    test "detects when multiple goal trees touch the same files" do
      # Goal 1 tree touches lib/parser.ex
      # Goal 2 tree touches lib/parser.ex
      file_map = %{
        1 => ["lib/parser.ex", "lib/lexer.ex"],
        2 => ["lib/parser.ex", "lib/router.ex"],
        3 => ["lib/views.ex"]
      }

      # Nodes 1 and 2 are roots, node 3 belongs to tree 1
      tree_membership = %{1 => 1, 2 => 2, 3 => 1}

      conflicts = Parser.detect_conflicts(file_map, tree_membership)

      assert length(conflicts) == 1
      [conflict] = conflicts
      assert conflict.file == "lib/parser.ex"
      assert Enum.sort(conflict.tree_ids) == [1, 2]
    end

    test "returns empty list when no conflicts" do
      file_map = %{1 => ["lib/a.ex"], 2 => ["lib/b.ex"]}
      tree_membership = %{1 => 1, 2 => 2}

      assert Parser.detect_conflicts(file_map, tree_membership) == []
    end
  end

  describe "build_tree_membership/2" do
    test "maps each node to its root goal tree" do
      nodes = [
        %{id: 1, type: :goal, status: :pending, title: "Root A"},
        %{id: 2, type: :action, status: :pending, title: "Action under A"},
        %{id: 3, type: :goal, status: :pending, title: "Root B"},
        %{id: 4, type: :action, status: :pending, title: "Action under B"}
      ]

      edges = [
        %{id: 1, from: 1, to: 2, type: :leads_to, rationale: ""},
        %{id: 2, from: 3, to: 4, type: :leads_to, rationale: ""}
      ]

      membership = Parser.build_tree_membership(nodes, edges)
      assert membership[1] == 1
      assert membership[2] == 1
      assert membership[3] == 3
      assert membership[4] == 3
    end
  end
end
