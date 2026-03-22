defmodule TermDiff.Agent.Runner do
  @moduledoc """
  Behaviour for agent session managers.

  Each implementation manages a single agent subprocess (Claude Code, etc.)
  and normalizes its output into the TermDiff event format.
  """

  @type config :: %{
          optional(:run_id) => integer(),
          optional(:model) => String.t(),
          optional(:max_turns) => pos_integer(),
          optional(:max_budget_usd) => float(),
          optional(:allowed_tools) => [String.t()],
          optional(:disallowed_tools) => [String.t()],
          optional(:permission_mode) => String.t(),
          optional(:system_prompt) => String.t(),
          optional(:append_system_prompt) => String.t(),
          optional(:interactive) => boolean(),
          optional(:resume_session_id) => String.t()
        }

  @type run_event :: %{
          type: String.t(),
          data: map(),
          timestamp: DateTime.t()
        }

  @callback start_run(config(), prompt :: String.t(), workspace :: String.t()) ::
              {:ok, pid()} | {:error, term()}

  @callback cancel_run(pid()) :: :ok | {:error, term()}

  @callback resume_run(session_id :: String.t(), prompt :: String.t()) ::
              {:ok, pid()} | {:error, term()}

  @callback respond_to_permission(
              pid(),
              tool_use_id :: String.t(),
              behavior :: String.t(),
              message :: String.t() | nil,
              updated_input :: map() | nil
            ) :: :ok | {:error, term()}

  @optional_callbacks [respond_to_permission: 5]
end
