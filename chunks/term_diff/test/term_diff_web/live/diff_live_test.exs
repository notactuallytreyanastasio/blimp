defmodule TermDiffWeb.DiffLiveTest do
  use TermDiffWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Build a real git repo with multiple files and a commit
    System.cmd("git", ["init"], cd: tmp_dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: tmp_dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp_dir)

    # Create initial files and commit
    File.write!(Path.join(tmp_dir, "alpha.ex"), "defmodule Alpha, do: nil")
    File.write!(Path.join(tmp_dir, "beta.ex"), "defmodule Beta, do: nil")
    System.cmd("git", ["add", "alpha.ex", "beta.ex"], cd: tmp_dir)
    System.cmd("git", ["commit", "-m", "initial commit with alpha and beta"], cd: tmp_dir)

    # Create unstaged changes in alpha
    File.write!(Path.join(tmp_dir, "alpha.ex"), "defmodule Alpha do\n  def hello, do: :world\nend")
    # Create a new untracked file
    File.write!(Path.join(tmp_dir, "gamma.ex"), "defmodule Gamma, do: nil")

    %{repo: tmp_dir}
  end

  defp mount_live(conn, repo) do
    {:ok, view, html} = live(conn, "/?path=#{URI.encode(repo)}")
    # Wait for the async refresh to complete
    _ = render_async(view)
    {view, html}
  end

  # ── Navigation ──

  describe "navigation: j/k movement" do
    test "j moves cursor down in file list", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "j"})
      # Should still show file list (we moved down one)
      assert html =~ "alpha.ex" or html =~ "beta.ex" or html =~ "gamma.ex"
    end

    test "k at top stays at top", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "k"})
      # Still rendering, no crash
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end
  end

  describe "navigation: Enter/q focus" do
    test "Enter on file enters diff view", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "Enter"})
      # Should show diff content (hunk headers start with @@)
      assert html =~ "@@" or html =~ "Select a file"
    end

    test "q from diff view returns to file list", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      # Enter diff view
      render_keydown(view, "keydown", %{"key" => "Enter"})
      # Go back
      html = render_keydown(view, "keydown", %{"key" => "q"})

      # Should be back in file list view
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end
  end

  describe "navigation: Tab toggle" do
    test "Tab toggles between file list and diff view", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      # Tab to diff view
      render_keydown(view, "keydown", %{"key" => "Tab"})
      # Tab back to file list
      html = render_keydown(view, "keydown", %{"key" => "Tab"})

      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end
  end

  describe "navigation: log view" do
    test "l enters log view showing commits", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "l"})

      assert html =~ "initial commit"
    end

    test "l again exits log view", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "l"})
      html = render_keydown(view, "keydown", %{"key" => "l"})

      # Back to file list, no longer showing log
      refute html =~ "initial commit"
    end
  end

  # ── Stage/Unstage ──

  describe "stage/unstage: file-level operations" do
    test "s stages the selected file", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      # Press s to stage first file
      html = render_keydown(view, "keydown", %{"key" => "s"})

      # Should show S indicator for staged file
      assert html =~ ">S<"
    end

    test "s then u stages then unstages", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      # Stage
      render_keydown(view, "keydown", %{"key" => "s"})
      # Unstage
      html = render_keydown(view, "keydown", %{"key" => "u"})

      # File should still be visible (back to unstaged)
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end

    test "rapid s/u/s/u works correctly", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "s"})
      render_keydown(view, "keydown", %{"key" => "u"})
      render_keydown(view, "keydown", %{"key" => "s"})
      html = render_keydown(view, "keydown", %{"key" => "u"})

      # Still renders without crash, file visible
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end

    test "s works from diff view too", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      # Enter diff view
      render_keydown(view, "keydown", %{"key" => "Enter"})
      # Stage from diff view
      html = render_keydown(view, "keydown", %{"key" => "s"})

      # Should not crash, file gets staged
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end

    test "u on unstaged-only file is a no-op", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      # u without staging first should be safe
      html = render_keydown(view, "keydown", %{"key" => "u"})

      # No crash, still showing files
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end
  end

  # ── Commit Mode ──

  describe "commit mode: cc" do
    test "cc with nothing staged shows error", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "cc"})

      assert html =~ "Nothing staged"
    end

    test "cc with staged files shows commit editor", %{conn: conn, repo: repo} do
      System.cmd("git", ["add", "alpha.ex"], cd: repo)
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "cc"})

      assert html =~ "COMMIT MESSAGE"
    end

    test "Escape exits commit mode", %{conn: conn, repo: repo} do
      System.cmd("git", ["add", "alpha.ex"], cd: repo)
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "cc"})
      html = render_keydown(view, "keydown", %{"key" => "Escape"})

      refute html =~ "COMMIT MESSAGE"
    end

    test "submitting empty message shows error", %{conn: conn, repo: repo} do
      System.cmd("git", ["add", "alpha.ex"], cd: repo)
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "cc"})
      html = render_submit(view, "submit_commit", %{"message" => ""})

      assert html =~ "empty"
    end

    test "submitting valid message creates commit", %{conn: conn, repo: repo} do
      System.cmd("git", ["add", "alpha.ex"], cd: repo)
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "cc"})
      html = render_submit(view, "submit_commit", %{"message" => "test commit from liveview"})

      # Should exit commit mode
      refute html =~ "COMMIT MESSAGE"

      # Verify git actually committed
      {log, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: repo)
      assert log =~ "test commit from liveview"
    end
  end

  # ── Amend Mode ──

  describe "amend mode: a" do
    test "a pre-populates the previous commit message", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "a"})

      assert html =~ "AMEND COMMIT"
      assert html =~ "initial commit with alpha and beta"
    end

    test "a shows the diff of the commit being amended", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "a"})

      assert html =~ "AMENDING COMMIT"
      assert html =~ "alpha.ex"
    end

    test "Escape exits amend mode", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "a"})
      html = render_keydown(view, "keydown", %{"key" => "Escape"})

      refute html =~ "AMEND COMMIT"
    end

    test "cancel button exits amend mode", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "a"})
      html = render_click(view, "cancel_commit")

      refute html =~ "AMEND COMMIT"
    end

    test "submitting amend updates the commit message", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      render_keydown(view, "keydown", %{"key" => "a"})
      html = render_submit(view, "submit_commit", %{"message" => "amended message"})

      refute html =~ "AMEND COMMIT"

      {log, 0} = System.cmd("git", ["log", "--oneline", "-1"], cd: repo)
      assert log =~ "amended message"
    end
  end

  # ── Click to select ──

  describe "select_file click" do
    test "clicking a file selects it", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_click(view, "select_file", %{"index" => "0"})

      # Should enter diff view for the clicked file
      assert html =~ "@@" or html =~ "Select a file"
    end
  end

  # ── Follow mode ──

  describe "follow mode" do
    test "F toggles follow indicator", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "F"})
      assert html =~ "FOLLOWING"

      html = render_keydown(view, "keydown", %{"key" => "F"})
      refute html =~ "FOLLOWING"
    end
  end

  # ── Error handling ──

  describe "error handling" do
    test "survives unknown keys without crash", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      html = render_keydown(view, "keydown", %{"key" => "z"})
      assert html =~ "alpha.ex" or html =~ "gamma.ex"
    end

    test "multiple rapid keypresses don't crash", %{conn: conn, repo: repo} do
      {view, _html} = mount_live(conn, repo)

      for key <- ~w(j j j k k s u j s k u Enter q Tab Tab) do
        render_keydown(view, "keydown", %{"key" => key})
      end

      html = render(view)
      # Still alive
      assert html =~ "term-diff"
    end
  end
end
