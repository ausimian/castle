defmodule Castle.DeploymentTest do
  # `RELDIR` and the SASL application environment both belong to the node, and
  # every other test relies on neither being set.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Castle.Deployment

  setup do
    sasl = Application.fetch_env(:sasl, :releases_dir)
    reldir = System.get_env("RELDIR")

    on_exit(fn ->
      case sasl do
        {:ok, dir} -> Application.put_env(:sasl, :releases_dir, dir)
        :error -> Application.delete_env(:sasl, :releases_dir)
      end

      if reldir, do: System.put_env("RELDIR", reldir), else: System.delete_env("RELDIR")
    end)

    Application.delete_env(:sasl, :releases_dir)
    System.delete_env("RELDIR")
    :ok
  end

  describe "releases_dir/0" do
    # Compared with what `:release_handler`'s own `init/1` decides, rather than
    # with a restatement of its rule, so that a precedence Castle got backwards
    # fails here - including on a deployment that sets only one of the two,
    # where getting the order wrong is otherwise invisible. `init/1` reads files
    # and the environment and starts nothing, and the directory is the
    # `rel_dir` field of its `#state{}`: `{state, unpurged, root, rel_dir, ...}`.
    # If OTP reorders that record this fails loudly rather than passing.
    @tag :tmp_dir
    test "agrees with :release_handler's own init/1", %{tmp_dir: dir} do
      by_sasl = Path.join(dir, "by-sasl")
      by_env = Path.join(dir, "by-env")

      assert Deployment.releases_dir() == Path.join(Deployment.root_dir(), "releases")
      assert Deployment.releases_dir() == handler_releases_dir()

      System.put_env("RELDIR", by_env)
      assert Deployment.releases_dir() == by_env
      assert Deployment.releases_dir() == handler_releases_dir()

      Application.put_env(:sasl, :releases_dir, to_charlist(by_sasl))
      assert Deployment.releases_dir() == by_sasl
      assert Deployment.releases_dir() == handler_releases_dir()

      System.delete_env("RELDIR")
      assert Deployment.releases_dir() == by_sasl
      assert Deployment.releases_dir() == handler_releases_dir()
    end

    # The handler keeps a relative directory as it was given and resolves it on
    # every file operation, through `root_dir_relative_path/1`, against
    # `code:root_dir()` - not against the working directory, which is what a
    # bare `Path.expand/1` would use.
    test "resolves a relative directory against the root" do
      System.put_env("RELDIR", "records/by-env")
      assert Deployment.releases_dir() == Path.join(Deployment.root_dir(), "records/by-env")

      Application.put_env(:sasl, :releases_dir, ~c"records/by-sasl")
      assert Deployment.releases_dir() == Path.join(Deployment.root_dir(), "records/by-sasl")
    end
  end

  describe "the command boundary" do
    # `Castle.make_releases/0` is the command #23 caught writing a RELEASES the
    # handler would never read. Here there is no release to create one from in
    # the directory RELDIR names, so it refuses - and the refusal naming that
    # directory is the evidence that the boundary derived it, rather than the
    # releases directory under the root.
    @tag :tmp_dir
    test "make_releases/0 works in the directory RELDIR names", %{tmp_dir: dir} do
      System.put_env("RELDIR", dir)

      capture_io(fn ->
        message = assert_raise(Castle.Error, &Castle.make_releases/0).message
        assert message =~ "RELEASES creation failed for #{Path.join(dir, "RELEASES")}"
      end)

      refute File.exists?(Path.join(dir, "RELEASES"))
    end
  end

  defp handler_releases_dir do
    {:ok, state} = :release_handler.init([])
    to_string(elem(state, 3))
  end
end
