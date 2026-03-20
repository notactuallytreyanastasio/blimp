defmodule TermDiff.Diff.CommitState do
  @moduledoc """
  Pure state machine for commit operations.

  Phases:
    :idle       -> not in commit flow
    :editing    -> user is writing a commit message
    :submitting -> commit is being executed
    :error      -> something went wrong (shown inline, user can cancel or retry)

  Modes:
    :commit -> regular git commit
    :amend  -> git commit --amend
  """

  @type phase :: :idle | :editing | :submitting | :error
  @type mode :: :commit | :amend | nil

  @type t :: %__MODULE__{
          phase: phase(),
          mode: mode(),
          message: String.t(),
          error: String.t() | nil
        }

  defstruct phase: :idle,
            mode: nil,
            message: "",
            error: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec enter(mode(), keyword()) :: t()
  def enter(:commit, opts) do
    staged_count = Keyword.get(opts, :staged_count, 0)

    if staged_count > 0 do
      %__MODULE__{phase: :editing, mode: :commit}
    else
      %__MODULE__{phase: :error, mode: :commit, error: "Nothing staged to commit"}
    end
  end

  def enter(:amend, opts) do
    last_message = Keyword.get(opts, :last_message)

    if last_message do
      %__MODULE__{phase: :editing, mode: :amend, message: String.trim(last_message)}
    else
      %__MODULE__{phase: :error, mode: :amend, error: "No commit to amend"}
    end
  end

  @spec update_message(t(), String.t()) :: t()
  def update_message(%{phase: :editing} = state, message) do
    %{state | message: message}
  end

  def update_message(state, _message), do: state

  @spec submit(t()) :: t()
  def submit(%{phase: :editing, message: message} = state) do
    if String.trim(message) == "" do
      %{state | phase: :error, error: "Commit message cannot be empty"}
    else
      %{state | phase: :submitting}
    end
  end

  def submit(state), do: state

  @spec complete(t()) :: t()
  def complete(%{phase: :submitting}) do
    %__MODULE__{}
  end

  def complete(state), do: state

  @spec fail(t(), String.t()) :: t()
  def fail(%{phase: :submitting} = state, reason) do
    %{state | phase: :error, error: reason}
  end

  def fail(state, _reason), do: state

  @spec cancel(t()) :: t()
  def cancel(_state), do: %__MODULE__{}

  @spec active?(t()) :: boolean()
  def active?(%{phase: :idle}), do: false
  def active?(_), do: true
end
