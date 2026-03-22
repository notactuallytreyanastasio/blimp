defmodule TermDiff.AI.Claude do
  @moduledoc """
  Shells out to `claude -p` over an Erlang Port for AI-powered code review.

  Instead of running a local LLM, this delegates to the Claude Code CLI
  which already has tool use, permissions, and context handling built in.
  Permissions are passed via --allowedTools so the subprocess can read
  files, run git commands, etc.
  """

  require Logger

  @default_allowed_tools "Read,Grep,Glob,Bash(git:*)"

  @spec default_allowed_tools() :: String.t()
  def default_allowed_tools, do: @default_allowed_tools

  @spec find_executable() :: String.t() | nil
  def find_executable do
    System.find_executable("claude")
  end

  @spec build_args(String.t(), String.t(), keyword()) :: [String.t()]
  def build_args(prompt, _repo_path, opts \\ []) do
    allowed_tools = Keyword.get(opts, :allowed_tools, @default_allowed_tools)
    system_prompt = Keyword.get(opts, :system_prompt)
    model = Keyword.get(opts, :model)
    json_schema = Keyword.get(opts, :json_schema)

    args = [
      "-p", prompt,
      "--output-format", "json",
      "--allowedTools", allowed_tools,
      "--permission-mode", "plan"
    ]

    args = if system_prompt, do: args ++ ["--system-prompt", system_prompt], else: args
    args = if model, do: args ++ ["--model", model], else: args
    args = if json_schema, do: args ++ ["--json-schema", json_schema], else: args

    args
  end

  @spec ask(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def ask(prompt, repo_path, opts \\ []) do
    claude = find_executable()
    repo_path = Path.expand(repo_path)

    cond do
      is_nil(claude) ->
        {:error, "claude executable not found in PATH"}

      not File.dir?(repo_path) ->
        {:error, "not a valid directory: #{repo_path}"}

      true ->
        args = build_args(prompt, repo_path, opts)
        run_port(claude, args, repo_path, opts)
    end
  end

  defp run_port(executable, args, repo_path, opts) do
    timeout = Keyword.get(opts, :timeout, 300_000)

    env =
      System.get_env()
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: repo_path,
        env: env
      ])

    collect_output(port, [], timeout)
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, [data | acc], timeout)

      {^port, {:exit_status, 0}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        parse_response(output)

      {^port, {:exit_status, code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, "claude exited with code #{code}: #{output}"}
    after
      timeout ->
        Port.close(port)
        {:error, "claude timed out after #{timeout}ms"}
    end
  end

  defp parse_response(output) do
    case Jason.decode(output) do
      {:ok, %{"result" => result}} ->
        {:ok, result}

      {:ok, %{"error" => error}} ->
        {:error, error}

      {:ok, other} ->
        {:ok, inspect(other)}

      {:error, _} ->
        # Fall back to raw text if not valid JSON
        {:ok, String.trim(output)}
    end
  end
end
