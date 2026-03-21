defmodule TermDiffWeb.Agent.EventProcessor do
  @moduledoc """
  Transforms raw Claude Code stream-json events into structured UI blocks.

  Used by RunDetailLive and AgentCard to convert flat event lists into
  a block-based representation suitable for rich rendering.

  ## Block Types

  - `:system` — Session init with model, session_id
  - `:text` — Claude's text response (merged from consecutive chunks)
  - `:tool_use` — Tool invocation with optional result attached
  - `:result` — Final summary with cost, tokens, turns
  """

  @type block :: map()
  @type event :: map()

  @doc """
  Process a full list of events into blocks.
  Used on mount for replaying persisted events.
  """
  @spec process_events([event()]) :: [block()]
  def process_events(events) do
    Enum.reduce(events, [], fn event, blocks -> append_event(event, blocks) end)
  end

  @doc """
  Append a single new event to the existing block list.
  Used for incremental streaming updates.
  """
  @spec append_event(event(), [block()]) :: [block()]

  # --- assistant event with content blocks list ---
  def append_event(%{"type" => "assistant", "message" => %{"content" => content_blocks}}, blocks)
      when is_list(content_blocks) do
    Enum.reduce(content_blocks, blocks, fn
      %{"type" => "text", "text" => text}, acc ->
        append_or_merge_text(acc, text)

      %{"type" => "tool_use", "name" => name} = block, acc ->
        id = Map.get(block, "id", "tool-#{length(acc)}")

        tool_block = %{
          type: :tool_use,
          id: "block-#{id}",
          tool_name: name,
          tool_use_id: id,
          input: Map.get(block, "input", %{}),
          result: nil,
          is_error: false,
          collapsed: true,
          streaming: false
        }

        acc ++ [tool_block]

      _other, acc ->
        acc
    end)
  end

  # --- assistant event with plain string content ---
  def append_event(%{"type" => "assistant", "message" => %{"content" => content}}, blocks)
      when is_binary(content) do
    append_or_merge_text(blocks, content)
  end

  # --- user event (tool results) ---
  def append_event(
        %{"type" => "user", "message" => %{"content" => content_blocks}} = event,
        blocks
      )
      when is_list(content_blocks) do
    Enum.reduce(content_blocks, blocks, fn
      %{"type" => "tool_result", "tool_use_id" => tool_use_id} = result, acc ->
        update_tool_block(acc, tool_use_id, fn block ->
          %{
            block
            | result: extract_tool_result(result, event),
              is_error: Map.get(result, "is_error", false)
          }
        end)

      _other, acc ->
        acc
    end)
  end

  # --- streaming text delta (unwrapped) ---
  def append_event(%{"type" => "content_block_delta", "delta" => %{"text" => text}}, blocks) do
    append_or_merge_text(blocks, text, streaming: true)
  end

  # --- stream_event wrapper containing content_block_delta with text ---
  def append_event(
        %{
          "type" => "stream_event",
          "event" => %{"type" => "content_block_delta", "delta" => %{"text" => text}}
        },
        blocks
      ) do
    append_or_merge_text(blocks, text, streaming: true)
  end

  # --- result event ---
  def append_event(%{"type" => "result"} = event, blocks) do
    # Only include result text if there are no prior text blocks
    # (the text was already shown via streaming assistant events)
    has_text_blocks = Enum.any?(blocks, &(&1.type == :text))

    result_data = %{
      text: if(has_text_blocks, do: nil, else: extract_result_text(event)),
      cost_usd: Map.get(event, "total_cost_usd") || Map.get(event, "cost_usd"),
      duration_ms: Map.get(event, "duration_ms"),
      num_turns: Map.get(event, "num_turns"),
      tokens: extract_usage(event)
    }

    blocks = finalize_streaming(blocks)
    upsert_result_block(blocks, result_data)
  end

  # --- system init ---
  def append_event(%{"type" => "system"} = event, blocks) do
    sys_block = %{
      type: :system,
      id: "block-system",
      session_id: Map.get(event, "session_id"),
      model: Map.get(event, "model"),
      version: Map.get(event, "claude_code_version")
    }

    blocks ++ [sys_block]
  end

  # --- raw output (non-JSON lines from stdout) ---
  def append_event(%{"type" => "raw_output", "content" => content}, blocks) do
    cleaned = strip_ansi(content)

    if cleaned == "" or String.match?(cleaned, ~r/^\s*$/) do
      blocks
    else
      append_or_merge_text(blocks, cleaned)
    end
  end

  # --- OpenCode ACP thought chunk (must be before text to match first) ---
  def append_event(%{"type" => "text", "thought" => true, "part" => %{"text" => text}}, blocks) do
    append_or_merge_text(blocks, text, streaming: true)
  end

  # --- OpenCode ACP text chunk ---
  def append_event(%{"type" => "text", "part" => %{"text" => text}}, blocks) do
    append_or_merge_text(blocks, text, streaming: true)
  end

  # --- OpenCode ACP tool_call ---
  def append_event(%{"type" => "tool_call", "part" => part}, blocks) do
    tool_use_id = Map.get(part, "toolCallId", "tool-#{length(blocks)}")
    status = Map.get(part, "status", "running")

    if find_tool_block(blocks, tool_use_id) do
      update_acp_tool_block(blocks, tool_use_id, part, status)
    else
      create_acp_tool_block(blocks, tool_use_id, part, status)
    end
  end

  # --- OpenCode ACP step_finish ---
  def append_event(%{"type" => "step_finish"}, blocks) do
    finalize_streaming(blocks)
  end

  # --- OpenCode ACP usage_update ---
  def append_event(%{"type" => "usage_update"} = event, blocks) do
    cost = get_in(event, ["cost", "amount"])

    if cost do
      result_data = %{
        text: nil,
        cost_usd: cost,
        duration_ms: nil,
        num_turns: nil,
        tokens: %{input: Map.get(event, "used", 0), output: 0}
      }

      upsert_result_block(blocks, result_data)
    else
      blocks
    end
  end

  # --- OpenCode ACP plan ---
  def append_event(%{"type" => "plan", "entries" => _entries}, blocks), do: blocks

  # --- skip noisy/meta events ---
  def append_event(%{"type" => "stream_event"}, blocks), do: blocks
  def append_event(%{"type" => "content_block_start"}, blocks), do: blocks
  def append_event(%{"type" => "content_block_stop"}, blocks), do: blocks
  def append_event(%{"type" => "message_start"}, blocks), do: blocks
  def append_event(%{"type" => "message_stop"}, blocks), do: blocks
  def append_event(%{"type" => "rate_limit_event"}, blocks), do: blocks
  def append_event(%{"type" => "permission_request"}, blocks), do: blocks
  def append_event(%{"type" => "ask_user_question"}, blocks), do: blocks

  # --- catch-all for unknown events ---
  def append_event(_event, blocks), do: blocks

  # -- Private Helpers ---

  @ansi_pattern ~r/(\x1b\[[0-9;]*[a-zA-Z]|\x1b\][\d;]*[^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]|\x1b\[[\?]?[0-9;]*[hlm]|\[\?[\d;]*[a-zA-Z]|\][\d;]*[^\]]*(?:\x07|))/

  defp strip_ansi(text) do
    text
    |> String.replace(@ansi_pattern, "")
    # Also strip common escape sequences that appear as literal bracket sequences
    |> String.replace(~r/\[[\?]?\d+[a-zA-Z]/, "")
    |> String.replace(~r/\]\d+;[^\]]*/, "")
    |> String.replace(~r/\[<u/, "")
  end

  defp append_or_merge_text(blocks, text, opts \\ []) do
    streaming = Keyword.get(opts, :streaming, false)

    case List.last(blocks) do
      %{type: :text} = last ->
        updated = %{last | content: last.content <> text, streaming: streaming}
        List.replace_at(blocks, length(blocks) - 1, updated)

      _ ->
        blocks ++
          [
            %{
              type: :text,
              id: "block-text-#{System.unique_integer([:positive])}",
              content: text,
              streaming: streaming
            }
          ]
    end
  end

  defp update_tool_block(blocks, tool_use_id, update_fn) do
    Enum.map(blocks, fn
      %{type: :tool_use, tool_use_id: ^tool_use_id} = block -> update_fn.(block)
      block -> block
    end)
  end

  defp extract_tool_result(%{"content" => content}, %{"tool_use_result" => tool_result})
       when is_map(tool_result) do
    %{
      content: content,
      stdout: Map.get(tool_result, "stdout"),
      stderr: Map.get(tool_result, "stderr"),
      interrupted: Map.get(tool_result, "interrupted", false),
      is_image: Map.get(tool_result, "isImage", false)
    }
  end

  defp extract_tool_result(%{"content" => content}, _event) do
    %{content: content}
  end

  defp extract_tool_result(_result, _event), do: nil

  defp extract_result_text(%{"result" => result}) when is_binary(result), do: result
  defp extract_result_text(_), do: nil

  defp extract_usage(%{"usage" => %{"input_tokens" => i, "output_tokens" => o}}),
    do: %{input: i, output: o}

  defp extract_usage(_), do: nil

  defp create_acp_tool_block(blocks, tool_use_id, part, status) do
    tool_block = %{
      type: :tool_use,
      id: "block-#{tool_use_id}",
      tool_name: Map.get(part, "title", "tool"),
      tool_use_id: tool_use_id,
      input: %{},
      result: nil,
      is_error: status == "error",
      collapsed: true,
      streaming: status == "running"
    }

    blocks = finalize_streaming_text(blocks)
    blocks ++ [tool_block]
  end

  defp update_acp_tool_block(blocks, tool_use_id, part, status) do
    new_content = Map.get(part, "content")

    update_tool_block(blocks, tool_use_id, fn block ->
      result = if new_content, do: %{content: new_content}, else: block.result
      %{block | result: result, is_error: status == "error", streaming: status == "running"}
    end)
  end

  defp find_tool_block(blocks, tool_use_id) do
    Enum.find(blocks, fn
      %{type: :tool_use, tool_use_id: ^tool_use_id} -> true
      _ -> false
    end)
  end

  defp upsert_result_block(blocks, result_data) do
    case Enum.find_index(blocks, &(&1.type == :result)) do
      nil ->
        # No existing result block -- create one
        block =
          Map.merge(result_data, %{
            type: :result,
            id: "block-result-#{System.unique_integer([:positive])}"
          })

        blocks ++ [block]

      idx ->
        # Update existing result block, preferring non-nil values from new data
        existing = Enum.at(blocks, idx)

        updated =
          %{
            existing
            | cost_usd: result_data.cost_usd || existing.cost_usd,
              duration_ms: result_data.duration_ms || existing.duration_ms,
              num_turns: result_data.num_turns || existing.num_turns,
              tokens: result_data.tokens || existing.tokens,
              text: result_data.text || existing.text
          }

        List.replace_at(blocks, idx, updated)
    end
  end

  defp finalize_streaming_text(blocks) do
    case List.last(blocks) do
      %{type: :text, streaming: true} = last ->
        List.replace_at(blocks, length(blocks) - 1, %{last | streaming: false})

      _ ->
        blocks
    end
  end

  defp finalize_streaming(blocks) do
    case List.last(blocks) do
      %{type: :text, streaming: true} = last ->
        List.replace_at(blocks, length(blocks) - 1, %{last | streaming: false})

      _ ->
        blocks
    end
  end
end
