defmodule TermDiff.Diff.LanguageTest do
  use ExUnit.Case, async: true

  alias TermDiff.Diff.Language

  describe "detect/1" do
    test "returns language for Elixir files" do
      assert Language.detect("lib/foo.ex") == "elixir"
      assert Language.detect("mix.exs") == "elixir"
    end

    test "returns language for Zig files" do
      assert Language.detect("src/parser.zig") == "zig"
    end

    test "returns language for JavaScript/TypeScript" do
      assert Language.detect("app.js") == "javascript"
      assert Language.detect("app.jsx") == "javascript"
      assert Language.detect("app.ts") == "typescript"
      assert Language.detect("app.tsx") == "typescript"
    end

    test "returns language for systems languages" do
      assert Language.detect("main.c") == "c"
      assert Language.detect("main.h") == "c"
      assert Language.detect("main.cpp") == "cpp"
      assert Language.detect("main.rs") == "rust"
      assert Language.detect("main.go") == "go"
      assert Language.detect("Main.java") == "java"
      assert Language.detect("main.swift") == "swift"
    end

    test "returns language for web languages" do
      assert Language.detect("index.html") == "xml"
      assert Language.detect("page.heex") == "xml"
      assert Language.detect("style.css") == "css"
      assert Language.detect("style.scss") == "scss"
    end

    test "returns language for data formats" do
      assert Language.detect("data.json") == "json"
      assert Language.detect("config.yaml") == "yaml"
      assert Language.detect("config.yml") == "yaml"
      assert Language.detect("config.toml") == "ini"
      assert Language.detect("doc.xml") == "xml"
    end

    test "returns language for scripting languages" do
      assert Language.detect("script.py") == "python"
      assert Language.detect("script.rb") == "ruby"
      assert Language.detect("script.sh") == "bash"
      assert Language.detect("script.bash") == "bash"
      assert Language.detect("script.lua") == "lua"
    end

    test "returns language for markup" do
      assert Language.detect("README.md") == "markdown"
      assert Language.detect("query.sql") == "sql"
      assert Language.detect("query.graphql") == "graphql"
    end

    test "handles special filenames" do
      assert Language.detect("Makefile") == "makefile"
      assert Language.detect("Dockerfile") == "dockerfile"
    end

    test "handles Blimp files as elixir (closest match)" do
      assert Language.detect("counter.blimp") == "elixir"
    end

    test "returns nil for unknown extensions" do
      assert Language.detect("file.xyz123") == nil
      assert Language.detect("file.unknown") == nil
    end

    test "returns nil for empty string" do
      assert Language.detect("") == nil
    end

    test "handles paths with directories" do
      assert Language.detect("src/lib/parser.rs") == "rust"
      assert Language.detect("chunks/term_diff/mix.exs") == "elixir"
      assert Language.detect("deep/nested/path/to/file.py") == "python"
    end

    test "returns nil for files without extensions that are not special" do
      assert Language.detect("README") == nil
      assert Language.detect("LICENSE") == nil
    end
  end
end
