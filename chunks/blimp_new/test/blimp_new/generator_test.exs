defmodule BlimpNew.GeneratorTest do
  use ExUnit.Case, async: true

  alias BlimpNew.Generator

  @test_app_name "my_shop"

  describe "validate_app_name/1" do
    test "accepts valid snake_case name" do
      assert :ok = Generator.validate_app_name("my_app")
    end

    test "accepts single word" do
      assert :ok = Generator.validate_app_name("shop")
    end

    test "rejects names starting with uppercase" do
      assert {:error, _} = Generator.validate_app_name("MyApp")
    end

    test "rejects names with dashes" do
      assert {:error, _} = Generator.validate_app_name("my-app")
    end

    test "rejects empty string" do
      assert {:error, _} = Generator.validate_app_name("")
    end

    test "rejects names starting with numbers" do
      assert {:error, _} = Generator.validate_app_name("1app")
    end
  end

  describe "build_assigns/2" do
    test "builds correct module names from app name" do
      assigns = Generator.build_assigns(@test_app_name, [])

      assert assigns.app_name == "my_shop"
      assert assigns.app_module == "MyShop"
      assert assigns.web_module == "MyShopWeb"
      assert assigns.repo_module == "MyShop.Repo"
      assert assigns.endpoint_module == "MyShopWeb.Endpoint"
      assert assigns.pubsub_module == "MyShop.PubSub"
    end

    test "includes actors flag when requested" do
      assigns = Generator.build_assigns(@test_app_name, actors: true)
      assert assigns.actors == true
    end

    test "actors default to false" do
      assigns = Generator.build_assigns(@test_app_name, [])
      assert assigns.actors == false
    end

    test "includes secret key base" do
      assigns = Generator.build_assigns(@test_app_name, [])
      assert is_binary(assigns.secret_key_base)
      assert byte_size(assigns.secret_key_base) >= 64
    end

    test "includes signing salt" do
      assigns = Generator.build_assigns(@test_app_name, [])
      assert is_binary(assigns.signing_salt)
      assert byte_size(assigns.signing_salt) >= 8
    end
  end

  describe "file_list/1" do
    test "includes core files" do
      assigns = Generator.build_assigns(@test_app_name, [])
      files = Generator.file_list(assigns)

      paths = Enum.map(files, fn {path, _} -> path end)

      assert "mix.exs" in paths
      assert "lib/my_shop/application.ex" in paths
      assert "lib/my_shop_web/router.ex" in paths
      assert "lib/my_shop_web/endpoint.ex" in paths
      assert "config/config.exs" in paths
      assert "config/dev.exs" in paths
      assert "config/prod.exs" in paths
      assert "config/runtime.exs" in paths
      assert "config/test.exs" in paths
      assert "assets/js/app.js" in paths
      assert "assets/css/app.css" in paths
      assert "Makefile" in paths
      assert "deploy.sh" in paths
    end

    test "includes actor files when actors enabled" do
      assigns = Generator.build_assigns(@test_app_name, actors: true)
      files = Generator.file_list(assigns)

      paths = Enum.map(files, fn {path, _} -> path end)

      assert "lib/my_shop/actors/supervisor.ex" in paths
      assert "lib/my_shop/actors/registry.ex" in paths
    end

    test "excludes actor files when actors disabled" do
      assigns = Generator.build_assigns(@test_app_name, [])
      files = Generator.file_list(assigns)

      paths = Enum.map(files, fn {path, _} -> path end)

      refute "lib/my_shop/actors/supervisor.ex" in paths
    end
  end
end
