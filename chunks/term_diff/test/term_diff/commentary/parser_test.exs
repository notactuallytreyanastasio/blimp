defmodule TermDiff.Commentary.ParserTest do
  use ExUnit.Case, async: true

  alias TermDiff.Commentary.Parser
  alias TermDiff.Commentary.{Annotation, ReviewResult}

  @valid_json Jason.encode!(%{
    "summary" => "Added a new module",
    "annotations" => [
      %{
        "file" => "lib/foo.ex",
        "start_line" => 10,
        "end_line" => 12,
        "comment" => "Missing error handling",
        "severity" => "warning"
      }
    ]
  })

  describe "parse_response/1" do
    test "parses valid JSON into ReviewResult" do
      assert {:ok, %ReviewResult{} = result} = Parser.parse_response(@valid_json)
      assert result.summary == "Added a new module"
      assert length(result.annotations) == 1
    end

    test "annotations have correct fields" do
      {:ok, result} = Parser.parse_response(@valid_json)
      [ann] = result.annotations
      assert %Annotation{} = ann
      assert ann.file == "lib/foo.ex"
      assert ann.start_line == 10
      assert ann.end_line == 12
      assert ann.comment == "Missing error handling"
      assert ann.severity == :warning
    end

    test "annotations get unique IDs" do
      json = Jason.encode!(%{
        "summary" => "test",
        "annotations" => [
          %{"file" => "a.ex", "start_line" => 1, "end_line" => 1, "comment" => "x", "severity" => "info"},
          %{"file" => "b.ex", "start_line" => 2, "end_line" => 2, "comment" => "y", "severity" => "info"}
        ]
      })

      {:ok, result} = Parser.parse_response(json)
      ids = Enum.map(result.annotations, & &1.id)
      assert length(Enum.uniq(ids)) == 2
    end

    test "handles JSON wrapped in markdown code fences" do
      input = "Here's my review:\n```json\n#{@valid_json}\n```\n"
      assert {:ok, %ReviewResult{}} = Parser.parse_response(input)
    end

    test "handles bare JSON without fences" do
      assert {:ok, %ReviewResult{}} = Parser.parse_response(@valid_json)
    end

    test "returns error for missing summary key" do
      json = ~s|{"annotations": []}|
      assert {:error, _} = Parser.parse_response(json)
    end

    test "returns error for missing annotations key" do
      json = ~s|{"summary": "hello"}|
      assert {:error, _} = Parser.parse_response(json)
    end

    test "returns error when no JSON found" do
      assert {:error, _} = Parser.parse_response("just some text with no json")
    end

    test "parses severity correctly" do
      make_json = fn sev ->
        ~s|{"summary": "t", "annotations": [{"file": "a.ex", "start_line": 1, "end_line": 1, "comment": "c", "severity": "#{sev}"}]}|
      end

      {:ok, r} = Parser.parse_response(make_json.("info"))
      assert hd(r.annotations).severity == :info

      {:ok, r} = Parser.parse_response(make_json.("warning"))
      assert hd(r.annotations).severity == :warning

      {:ok, r} = Parser.parse_response(make_json.("issue"))
      assert hd(r.annotations).severity == :issue

      {:ok, r} = Parser.parse_response(make_json.("unknown"))
      assert hd(r.annotations).severity == :info
    end

    test "handles empty annotations list" do
      json = ~s|{"summary": "Nothing notable", "annotations": []}|
      {:ok, result} = Parser.parse_response(json)
      assert result.annotations == []
      assert result.summary == "Nothing notable"
    end

    test "sets reviewed_at to current time" do
      {:ok, result} = Parser.parse_response(@valid_json)
      assert %DateTime{} = result.reviewed_at
      assert DateTime.diff(DateTime.utc_now(), result.reviewed_at, :second) < 2
    end
  end
end
