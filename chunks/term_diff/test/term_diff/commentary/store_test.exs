defmodule TermDiff.Commentary.StoreTest do
  use ExUnit.Case, async: true

  alias TermDiff.Commentary.Store
  alias TermDiff.Commentary.{Annotation, FileCommentary, ReviewResult}

  setup do
    name = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: name})
    %{store: name}
  end

  defp make_annotation(file, start_line, end_line, opts \\ []) do
    %Annotation{
      file: file,
      start_line: start_line,
      end_line: end_line,
      comment: Keyword.get(opts, :comment, "test comment"),
      severity: Keyword.get(opts, :severity, :info),
      id: Keyword.get(opts, :id, Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    }
  end

  defp make_review(annotations, opts \\ []) do
    %ReviewResult{
      summary: Keyword.get(opts, :summary, "test summary"),
      annotations: annotations,
      diff_hash: Keyword.get(opts, :diff_hash, "abc123"),
      reviewed_at: DateTime.utc_now()
    }
  end

  describe "put_review/1" do
    test "stores review result", %{store: s} do
      ann = make_annotation("lib/foo.ex", 10, 12)
      review = make_review([ann])

      :ok = Store.put_review(review, s)
      assert Store.get_summary(s) == "test summary"
    end

    test "groups annotations by file", %{store: s} do
      anns = [
        make_annotation("lib/foo.ex", 1, 3),
        make_annotation("lib/foo.ex", 10, 12),
        make_annotation("lib/bar.ex", 5, 5)
      ]

      :ok = Store.put_review(make_review(anns), s)

      foo = Store.get_file_commentary("lib/foo.ex", s)
      assert length(foo.annotations) == 2

      bar = Store.get_file_commentary("lib/bar.ex", s)
      assert length(bar.annotations) == 1
    end
  end

  describe "get_file_commentary/1" do
    test "returns FileCommentary for known file", %{store: s} do
      ann = make_annotation("lib/foo.ex", 10, 12)
      :ok = Store.put_review(make_review([ann]), s)

      result = Store.get_file_commentary("lib/foo.ex", s)
      assert %FileCommentary{} = result
      assert result.file == "lib/foo.ex"
      assert result.staleness == :fresh
    end

    test "returns nil for unknown file", %{store: s} do
      assert Store.get_file_commentary("nope.ex", s) == nil
    end
  end

  describe "get_annotations_for_line/2" do
    test "returns annotations covering a line", %{store: s} do
      ann = make_annotation("lib/foo.ex", 10, 15)
      :ok = Store.put_review(make_review([ann]), s)

      assert [%Annotation{}] = Store.get_annotations_for_line("lib/foo.ex", 12, s)
    end

    test "returns empty list for uncovered line", %{store: s} do
      ann = make_annotation("lib/foo.ex", 10, 15)
      :ok = Store.put_review(make_review([ann]), s)

      assert [] = Store.get_annotations_for_line("lib/foo.ex", 20, s)
    end

    test "returns empty list for unknown file", %{store: s} do
      assert [] = Store.get_annotations_for_line("nope.ex", 1, s)
    end
  end

  describe "mark_stale/1" do
    test "changes staleness from fresh to stale", %{store: s} do
      ann = make_annotation("lib/foo.ex", 1, 1)
      :ok = Store.put_review(make_review([ann]), s)

      assert Store.get_file_commentary("lib/foo.ex", s).staleness == :fresh

      Store.mark_stale(["lib/foo.ex"], s)

      assert Store.get_file_commentary("lib/foo.ex", s).staleness == :stale
    end

    test "ignores unknown files", %{store: s} do
      Store.mark_stale(["nope.ex"], s)
    end
  end

  describe "get_status/0 and mark_reviewing/0" do
    test "starts as idle", %{store: s} do
      assert Store.get_status(s) == :idle
    end

    test "mark_reviewing sets status", %{store: s} do
      Store.mark_reviewing(s)
      assert Store.get_status(s) == :reviewing
    end

    test "put_review resets status to idle", %{store: s} do
      Store.mark_reviewing(s)
      :ok = Store.put_review(make_review([]), s)
      assert Store.get_status(s) == :idle
    end
  end

  describe "clear/0" do
    test "removes all data", %{store: s} do
      ann = make_annotation("lib/foo.ex", 1, 1)
      :ok = Store.put_review(make_review([ann]), s)

      Store.clear(s)

      assert Store.get_file_commentary("lib/foo.ex", s) == nil
      assert Store.get_summary(s) == nil
      assert Store.get_status(s) == :idle
    end
  end
end
