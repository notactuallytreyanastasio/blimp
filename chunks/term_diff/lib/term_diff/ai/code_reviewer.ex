defmodule TermDiff.AI.CodeReviewer do
  @moduledoc """
  LangChain-powered code review agent that talks to Ollama.

  Provides tools for the LLM to inspect a repository: read files,
  view diffs, check git status, and list directory contents.
  The agent can then comment on code changes with full context.
  """

  alias LangChain.Chains.LLMChain
  alias LangChain.ChatModels.ChatOllamaAI
  alias LangChain.Function
  alias LangChain.FunctionParam
  alias LangChain.Message

  @default_model "llama3.2:latest"
  @default_endpoint "http://localhost:11434/api/chat"

  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are a code review agent embedded in a diff viewer.
    You can read files, view git diffs, check git status, and list directory contents.
    # TODO add cicada so theres introspection at the level of LSP

    When reviewing code changes:
    - Use your tools to inspect the actual code before commenting
    - Be specific: reference file names, line numbers, function names
    - Focus on substance: bugs, logic errors, missing edge cases, unclear naming
    - Skip trivial style nits unless they hurt readability
    - Keep commentary concise and direct
    """
  end

  @spec tools(String.t()) :: [Function.t()]
  def tools(repo_path) do
    [
      read_file_tool(repo_path),
      git_diff_tool(repo_path),
      git_status_tool(repo_path),
      list_files_tool(repo_path)
    ]
  end

  @spec build_chain(String.t(), keyword()) :: LLMChain.t()
  def build_chain(repo_path, opts \\ []) do
    model = Keyword.get(opts, :model, @default_model)
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000 * 5)

    llm =
      ChatOllamaAI.new!(%{
        model: model,
        endpoint: endpoint,
        receive_timeout: receive_timeout,
        # we totally should be streaming
        stream: false
      })

    %{llm: llm}
    |> LLMChain.new!()
    |> LLMChain.add_tools(tools(repo_path))
  end

  @spec review(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def review(repo_path, prompt, opts \\ []) do
    chain = build_chain(repo_path, opts)

    result =
      try do
        chain
        |> LLMChain.add_message(Message.new_system!(system_prompt()))
        |> LLMChain.add_message(Message.new_user!(prompt))
        |> LLMChain.run(mode: :while_needs_response)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        :exit, reason -> {:error, "Connection failed: #{inspect(reason)}"}
      end

    case result do
      {:ok, updated_chain} ->
        {:ok, updated_chain.last_message.content}

      {:error, _chain, %LangChain.LangChainError{message: reason}} ->
        {:error, reason}

      {:error, _chain, reason} ->
        {:error, to_string(reason)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Tool Definitions ──

  defp read_file_tool(repo_path) do
    Function.new!(%{
      name: "read_file",
      description:
        "Read the contents of a file in the repository. Returns the file content as text.",
      parameters: [
        FunctionParam.new!(%{
          name: "path",
          type: :string,
          required: true,
          description: "Relative path to the file from the repository root"
        })
      ],
      function: fn %{"path" => path}, _context ->
        full_path = Path.join(repo_path, path)

        case File.read(full_path) do
          {:ok, content} -> {:ok, content}
          {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
        end
      end
    })
  end

  defp git_diff_tool(repo_path) do
    Function.new!(%{
      name: "git_diff",
      description:
        "Show the current git diff (unstaged changes). Optionally for a specific file.",
      parameters: [
        FunctionParam.new!(%{
          name: "file",
          type: :string,
          required: false,
          description: "Optional file path to diff. If omitted, shows all changes."
        })
      ],
      function: fn args, _context ->
        extra_args =
          case Map.get(args, "file") do
            nil -> []
            "" -> []
            file -> ["--", file]
          end

        case System.cmd("git", ["diff"] ++ extra_args, cd: repo_path, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {error, _} -> {:error, error}
        end
      end
    })
  end

  defp git_status_tool(repo_path) do
    Function.new!(%{
      name: "git_status",
      description: "Show the current git status: which files are modified, staged, or untracked.",
      parameters: [],
      function: fn _args, _context ->
        case System.cmd("git", ["status", "--porcelain=v1", "-u"],
               cd: repo_path,
               stderr_to_stdout: true
             ) do
          {output, 0} -> {:ok, output}
          {error, _} -> {:error, error}
        end
      end
    })
  end

  defp list_files_tool(repo_path) do
    Function.new!(%{
      name: "list_files",
      description: "List files in a directory within the repository.",
      parameters: [
        FunctionParam.new!(%{
          name: "directory",
          type: :string,
          required: false,
          description: "Relative directory path. Defaults to repository root if omitted."
        })
      ],
      function: fn args, _context ->
        dir =
          case Map.get(args, "directory") do
            nil -> repo_path
            "" -> repo_path
            subdir -> Path.join(repo_path, subdir)
          end

        case File.ls(dir) do
          {:ok, entries} -> {:ok, Enum.sort(entries) |> Enum.join("\n")}
          {:error, reason} -> {:error, "Cannot list #{dir}: #{reason}"}
        end
      end
    })
  end
end
