defmodule TermDiff.Diff.Navigation do
  @moduledoc "Pure state machine for keyboard-driven diff navigation. No side effects."

  @type focus :: :file_list | :diff_view | :log_view | :log_detail

  @type t :: %__MODULE__{
          focus: focus(),
          file_index: non_neg_integer(),
          hunk_index: non_neg_integer(),
          log_index: non_neg_integer(),
          file_count: non_neg_integer(),
          hunk_count: non_neg_integer(),
          log_count: non_neg_integer(),
          selected_file: String.t() | nil,
          selected_commit: String.t() | nil,
          expanded_hunks: MapSet.t(),
          following: boolean(),
          open_file: String.t() | nil,
          stage_file: String.t() | nil,
          unstage_file: String.t() | nil
        }

  defstruct focus: :file_list,
            file_index: 0,
            hunk_index: 0,
            log_index: 0,
            file_count: 0,
            hunk_count: 0,
            log_count: 0,
            selected_file: nil,
            selected_commit: nil,
            expanded_hunks: MapSet.new(),
            following: false,
            open_file: nil,
            stage_file: nil,
            unstage_file: nil

  @spec handle_key(t(), String.t()) :: t()
  def handle_key(nav, "j"), do: move_down(nav)
  def handle_key(nav, "k"), do: move_up(nav)
  def handle_key(nav, "Enter"), do: select(nav)
  def handle_key(nav, "q"), do: go_back(nav)
  def handle_key(nav, "Tab"), do: toggle_focus(nav)
  def handle_key(nav, "F"), do: toggle_follow(nav)
  def handle_key(nav, "l"), do: toggle_log(nav)
  def handle_key(nav, "o"), do: open_selected(nav)
  def handle_key(nav, "s"), do: stage_selected(nav)
  def handle_key(nav, "u"), do: unstage_selected(nav)
  def handle_key(nav, _), do: nav

  @spec move_down(t()) :: t()
  defp move_down(%{focus: :file_list} = nav) do
    %{nav | file_index: min(nav.file_index + 1, max(nav.file_count - 1, 0))}
  end

  defp move_down(%{focus: :diff_view} = nav) do
    %{nav | hunk_index: min(nav.hunk_index + 1, max(nav.hunk_count - 1, 0))}
  end

  defp move_down(%{focus: :log_view} = nav) do
    %{nav | log_index: min(nav.log_index + 1, max(nav.log_count - 1, 0))}
  end

  defp move_down(%{focus: :log_detail} = nav) do
    %{nav | hunk_index: min(nav.hunk_index + 1, max(nav.hunk_count - 1, 0))}
  end

  @spec move_up(t()) :: t()
  defp move_up(%{focus: :file_list} = nav) do
    %{nav | file_index: max(nav.file_index - 1, 0)}
  end

  defp move_up(%{focus: :diff_view} = nav) do
    %{nav | hunk_index: max(nav.hunk_index - 1, 0)}
  end

  defp move_up(%{focus: :log_view} = nav) do
    %{nav | log_index: max(nav.log_index - 1, 0)}
  end

  defp move_up(%{focus: :log_detail} = nav) do
    %{nav | hunk_index: max(nav.hunk_index - 1, 0)}
  end

  @spec select(t()) :: t()
  defp select(%{focus: :file_list, file_count: 0} = nav), do: nav

  defp select(%{focus: :file_list} = nav) do
    %{nav | focus: :diff_view, hunk_index: 0}
  end

  defp select(%{focus: :diff_view} = nav) do
    hunk_key = {nav.selected_file, nav.hunk_index}

    expanded =
      if MapSet.member?(nav.expanded_hunks, hunk_key) do
        MapSet.delete(nav.expanded_hunks, hunk_key)
      else
        MapSet.put(nav.expanded_hunks, hunk_key)
      end

    %{nav | expanded_hunks: expanded}
  end

  defp select(%{focus: :log_view} = nav) do
    %{nav | focus: :log_detail, hunk_index: 0}
  end

  defp select(%{focus: :log_detail} = nav), do: nav

  @spec go_back(t()) :: t()
  defp go_back(%{focus: :diff_view} = nav) do
    %{nav | focus: :file_list, hunk_index: 0}
  end

  defp go_back(%{focus: :log_detail} = nav) do
    %{nav | focus: :log_view, hunk_index: 0, selected_commit: nil}
  end

  defp go_back(%{focus: :log_view} = nav) do
    %{nav | focus: :file_list, log_index: 0}
  end

  defp go_back(nav), do: nav

  @spec toggle_focus(t()) :: t()
  defp toggle_focus(%{focus: :file_list} = nav), do: %{nav | focus: :diff_view}
  defp toggle_focus(%{focus: :diff_view} = nav), do: %{nav | focus: :file_list}
  defp toggle_focus(nav), do: nav

  @spec toggle_follow(t()) :: t()
  defp toggle_follow(nav), do: %{nav | following: not nav.following}

  @spec toggle_log(t()) :: t()
  defp toggle_log(%{focus: :log_view} = nav), do: %{nav | focus: :file_list, log_index: 0}
  defp toggle_log(%{focus: :log_detail} = nav), do: %{nav | focus: :file_list, log_index: 0, selected_commit: nil}
  defp toggle_log(nav), do: %{nav | focus: :log_view, log_index: 0}

  @spec open_selected(t()) :: t()
  defp open_selected(%{focus: :file_list} = nav) do
    %{nav | open_file: nav.selected_file}
  end

  defp open_selected(nav), do: nav

  @spec stage_selected(t()) :: t()
  defp stage_selected(%{selected_file: nil} = nav), do: nav
  defp stage_selected(%{focus: focus} = nav) when focus in [:file_list, :diff_view] do
    %{nav | stage_file: nav.selected_file}
  end
  defp stage_selected(nav), do: nav

  @spec unstage_selected(t()) :: t()
  defp unstage_selected(%{selected_file: nil} = nav), do: nav
  defp unstage_selected(%{focus: focus} = nav) when focus in [:file_list, :diff_view] do
    %{nav | unstage_file: nav.selected_file}
  end
  defp unstage_selected(nav), do: nav

  @spec clear_open_file(t()) :: t()
  def clear_open_file(nav), do: %{nav | open_file: nil}

  @spec clear_stage_action(t()) :: t()
  def clear_stage_action(nav), do: %{nav | stage_file: nil, unstage_file: nil}

  @spec sync_to_files(t(), [String.t()]) :: t()
  def sync_to_files(nav, file_paths) do
    count = length(file_paths)

    case count do
      0 ->
        %{nav | file_index: 0, file_count: 0, selected_file: nil}

      _ ->
        idx = find_file_index(file_paths, nav.selected_file, nav.file_index)
        %{nav | file_index: idx, file_count: count, selected_file: Enum.at(file_paths, idx)}
    end
  end

  defp find_file_index(file_paths, nil, current_index) do
    min(current_index, length(file_paths) - 1) |> max(0)
  end

  defp find_file_index(file_paths, selected_file, current_index) do
    case Enum.find_index(file_paths, &(&1 == selected_file)) do
      nil -> min(current_index, length(file_paths) - 1) |> max(0)
      idx -> idx
    end
  end

  @spec follow_to_latest(t(), String.t() | nil, non_neg_integer()) :: t()
  def follow_to_latest(%{following: false} = nav, _file, _hunk_count), do: nav
  def follow_to_latest(%{following: true} = nav, nil, _hunk_count), do: nav

  def follow_to_latest(%{following: true} = nav, file, hunk_count) do
    %{nav | selected_file: file, focus: :diff_view, hunk_index: max(hunk_count - 1, 0)}
  end
end
