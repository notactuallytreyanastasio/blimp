defmodule TermDiff.Diff.FileState do
  @moduledoc """
  Per-file state machine for git staging lifecycle.

  Every file in git status is in exactly one state. Each state
  determines what `stage` and `unstage` commands are valid and
  what git command to run.

  ## State Graph

                      +-------------+
                      |  untracked  |  ?? in porcelain
                      +------+------+
                        s: git add
                             |
                      +------v------+
                +-----|  staged_new |  A_ in porcelain
                |     +------+------+
           u: git rm         | commit
             --cached        |
                |     +------v------+
                +---->|   clean     |  not in status output
                      +--+------+--+
                  edit   |      | delete
                         |      |
                +--------v+  +--v----------+
                |unstaged_ |  |unstaged_    |
                |modified  |  |deleted      |
                | _M       |  | _D          |
                +----+-----+  +------+------+
              s: git add        s: git add
                     |               |
                +----v-----+  +------v------+
                |staged_   |  |staged_      |
                |modified  |  |deleted      |
                | M_       |  | D_          |
                +----+-----+  +------+------+
          u: restore |        u: restore
            --staged |          --staged
                     |               |
                +----v-----+  +------v------+
                |unstaged_ |  |unstaged_    |
                |modified  |  |deleted      |
                +----------+  +-------------+

      Also: MM (staged+unstaged modified), AM, MD, etc.

  ## States

    :untracked         - ?? - new file, not in index
    :staged_new        - A_ - new file added to index
    :unstaged_modified - _M - tracked file with working tree changes
    :staged_modified   - M_ - tracked file with staged changes only
    :partial_modified  - MM - tracked file with both staged and unstaged changes
    :unstaged_deleted  - _D - tracked file deleted in working tree
    :staged_deleted    - D_ - deletion staged in index
    :staged_renamed    - R_ - rename staged in index

  ## Commands

  Returned by stage_command/1 and unstage_command/1:

    {:add, path}            - git add <path>
    {:rm_cached, path}      - git rm --cached <path>
    {:restore_staged, path} - git restore --staged <path>
    :noop                   - no action needed
  """

  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :path, :string

    field :status, Ecto.Enum,
      values: [
        :untracked,
        :staged_new,
        :unstaged_modified,
        :staged_modified,
        :partial_modified,
        :unstaged_deleted,
        :staged_deleted,
        :staged_renamed
      ]
  end

  @type status ::
          :untracked
          | :staged_new
          | :unstaged_modified
          | :staged_modified
          | :partial_modified
          | :unstaged_deleted
          | :staged_deleted
          | :staged_renamed

  @type command ::
          {:add, String.t()} | {:rm_cached, String.t()} | {:restore_staged, String.t()} | :noop

  @type t :: %__MODULE__{path: String.t(), status: status()}

  @spec from_status(String.t(), String.t()) :: t()
  def from_status(<<staged, unstaged>>, path) do
    %__MODULE__{path: path, status: parse_pair(staged, unstaged)}
  end

  def from_status(_, path) do
    %__MODULE__{path: path, status: :untracked}
  end

  @spec stage_command(t()) :: command()
  def stage_command(%{status: status, path: path})
      when status in [:untracked, :unstaged_modified, :unstaged_deleted, :partial_modified] do
    {:add, path}
  end

  def stage_command(_), do: :noop

  @spec unstage_command(t()) :: command()
  def unstage_command(%{status: :staged_new, path: path}), do: {:rm_cached, path}

  def unstage_command(%{status: status, path: path})
      when status in [:staged_modified, :staged_deleted, :staged_renamed, :partial_modified] do
    {:restore_staged, path}
  end

  def unstage_command(_), do: :noop

  @spec stageable?(t()) :: boolean()
  def stageable?(%{status: s}),
    do: s in [:untracked, :unstaged_modified, :unstaged_deleted, :partial_modified]

  @spec unstageable?(t()) :: boolean()
  def unstageable?(%{status: s}),
    do: s in [:staged_new, :staged_modified, :staged_deleted, :staged_renamed, :partial_modified]

  # ── Porcelain parsing ──

  defp parse_pair(??, ??), do: :untracked
  defp parse_pair(?A, ?\s), do: :staged_new
  defp parse_pair(?A, ?M), do: :partial_modified
  defp parse_pair(?\s, ?M), do: :unstaged_modified
  defp parse_pair(?M, ?\s), do: :staged_modified
  defp parse_pair(?M, ?M), do: :partial_modified
  defp parse_pair(?\s, ?D), do: :unstaged_deleted
  defp parse_pair(?D, ?\s), do: :staged_deleted
  defp parse_pair(?R, ?\s), do: :staged_renamed
  defp parse_pair(?R, ?M), do: :partial_modified
  defp parse_pair(_, _), do: :untracked
end
