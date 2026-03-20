defmodule TermDiff.Commentary.ServerTest do
  use ExUnit.Case, async: true

  alias TermDiff.Commentary.{Server, Store}

  setup do
    store_name = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Store, name: store_name})

    unless Process.whereis(TermDiff.PubSub) do
      start_supervised!({Phoenix.PubSub, name: TermDiff.PubSub})
    end

    Phoenix.PubSub.subscribe(TermDiff.PubSub, "commentary:updates")

    task_sup_name = :"task_sup_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: task_sup_name})

    %{store: store_name, task_sup: task_sup_name}
  end

  defp start_server(ctx, opts \\ []) do
    default_caller = fn _prompt, _repo_path, _opts ->
      {:ok,
       Jason.encode!(%{
         "summary" => "test summary",
         "annotations" => [
           %{
             "file" => "lib/foo.ex",
             "start_line" => 1,
             "end_line" => 3,
             "comment" => "looks good",
             "severity" => "info"
           }
         ]
       })}
    end

    caller = Keyword.get(opts, :caller, default_caller)
    server_name = :"server_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Server,
       name: server_name,
       repo_path: "/tmp/fake_repo",
       caller: caller,
       store: ctx.store,
       task_supervisor: ctx.task_sup}
    )

    server_name
  end

  describe "request_review/2" do
    test "stores results after completion", ctx do
      server = start_server(ctx)
      Server.request_review("diff content", "/tmp/fake_repo", server)

      assert_receive :commentary_ready, 2000

      assert Store.get_summary(ctx.store) == "test summary"
      assert Store.get_file_commentary("lib/foo.ex", ctx.store) != nil
    end

    test "broadcasts commentary_ready on PubSub", ctx do
      server = start_server(ctx)
      Server.request_review("diff content", "/tmp/fake_repo", server)

      assert_receive :commentary_ready, 2000
    end

    test "skips review when diff hash unchanged", ctx do
      call_count = :counters.new(1, [:atomics])

      caller = fn _prompt, _repo_path, _opts ->
        :counters.add(call_count, 1, 1)
        {:ok, Jason.encode!(%{"summary" => "s", "annotations" => []})}
      end

      server = start_server(ctx, caller: caller)

      Server.request_review("same diff", "/tmp/fake_repo", server)
      assert_receive :commentary_ready, 2000

      Server.request_review("same diff", "/tmp/fake_repo", server)
      assert_receive :commentary_ready, 2000

      assert :counters.get(call_count, 1) == 1
    end

    test "re-reviews when diff changes", ctx do
      call_count = :counters.new(1, [:atomics])

      caller = fn _prompt, _repo_path, _opts ->
        :counters.add(call_count, 1, 1)
        {:ok, Jason.encode!(%{"summary" => "s", "annotations" => []})}
      end

      server = start_server(ctx, caller: caller)

      Server.request_review("diff v1", "/tmp/fake_repo", server)
      assert_receive :commentary_ready, 2000

      Server.request_review("diff v2", "/tmp/fake_repo", server)
      assert_receive :commentary_ready, 2000

      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "error handling" do
    test "handles caller errors gracefully", ctx do
      caller = fn _prompt, _repo_path, _opts ->
        {:error, "connection failed"}
      end

      server = start_server(ctx, caller: caller)
      Server.request_review("diff content", "/tmp/fake_repo", server)

      assert_receive :commentary_error, 2000
    end
  end
end
