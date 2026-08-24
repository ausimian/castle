defmodule Castle.CustomizeTest do
  use ExUnit.Case, async: false

  # `customize/1` is a pure function on a keyword list, so none of this needs a
  # release, a project or a filesystem. What it does need is Mix's shell, which
  # is where the missing-`:tar` warning goes and which is one setting for the
  # whole node - so this file is `async: false`, and ExUnit then runs it while
  # nothing else is running. It is the file rather than the cases that look at
  # the warning, because the two that assert nothing was said depend on the
  # shell being the one this `setup` installed just as much as the one that
  # asserts something was.
  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  # Every assertion below is on the *whole* steps list, in order. A test that
  # asked only whether `:steps` was present, or whether the two Castle steps
  # appeared in it, would pass against a splice that put them the wrong side of
  # `:assemble` - and the wrong side is the only way to get this wrong, since
  # `pre_assemble/1` prepares what `:assemble` writes and `post_assemble/1`
  # reads what it wrote.
  describe "customize/1" do
    test "puts the Castle steps either side of :assemble" do
      assert Castle.customize(steps: [:assemble, :tar]) ==
               [steps: [pre(), :assemble, post(), :tar]]
    end

    # Not just that they survive, but that they stay where they were: a project
    # writes a step before `:assemble` because it has to run before the release
    # is written, and one after because it has to run on what was written.
    test "keeps the project's own steps, and their order" do
      own_pre = fn release -> release end
      own_post = fn release -> release end

      assert Castle.customize(steps: [own_pre, :assemble, own_post, :tar]) ==
               [steps: [own_pre, pre(), :assemble, post(), own_post, :tar]]
    end

    # `:steps` absent is the case a project reaches by saying nothing, so the
    # default is what most releases will be built with. It is Mix's default plus
    # `:tar`: see the @doc, and the missing-`:tar` cases below.
    test "defaults :steps to Mix's own plus :tar when there is none" do
      assert Castle.customize([]) == [steps: [pre(), :assemble, post(), :tar]]
    end

    test "leaves every other release option exactly as it was" do
      opts = [
        include_executables_for: [:unix],
        applications: [my_app: :permanent],
        strip_beams: false,
        steps: [:assemble, :tar]
      ]

      customized = Castle.customize(opts)

      assert Keyword.delete(customized, :steps) == Keyword.delete(opts, :steps)
      assert customized[:steps] == [pre(), :assemble, post(), :tar]
    end

    test "adds :steps without disturbing the options that were there" do
      assert Castle.customize(include_executables_for: [:unix]) ==
               [include_executables_for: [:unix], steps: [pre(), :assemble, post(), :tar]]
    end

    # There is nowhere to splice, so nothing is spliced. `mix release` requires
    # exactly one `:assemble` and refuses this list itself, naming the option -
    # which is why nothing here tries to say it first.
    test "hands back a list with no :assemble untouched" do
      own = fn release -> release end

      assert Castle.customize(steps: [own]) == [steps: [own]]
      refute_received {:mix_shell, :error, _}
    end

    # Same reason, one layer down: `Forecastle.steps/1` requires a list, and a
    # FunctionClauseError out of it would name a module the project never
    # mentioned. `mix release` validates the value and says what it should be.
    test "hands back a :steps value that is not a list untouched" do
      assert Castle.customize(steps: :assemble) == [steps: :assemble]
      refute_received {:mix_shell, :error, _}
    end
  end

  # The decision, pinned in both halves: the project's list is built as the
  # project wrote it, and the build says what that costs. `:tar` is not added
  # back - a test that only checked for the warning would pass against a
  # `customize/1` that quietly appended one.
  describe "customize/1 with a :steps list that has no :tar" do
    test "honours the list as it stands" do
      assert Castle.customize(steps: [:assemble]) == [steps: [pre(), :assemble, post()]]
    end

    test "warns, naming the step, the file and the command that reads it" do
      Castle.customize(steps: [:assemble])

      assert_received {:mix_shell, :error, [message]}
      assert message =~ ":tar"
      assert message =~ "<name>-<vsn>.tar.gz"
      assert message =~ "bin/castle unpack"
    end

    test "claims no verdict about whether an archive appears" do
      # All this can see is one atom missing from the list as given. A function
      # step later in the list can pack an archive itself, or add `:tar` to the
      # steps still to run - `%Mix.Release{}` carries those precisely so a step
      # can - so the absence of the atom is not the absence of a tarball.
      #
      # Asserted as the absence of the assertions, because that is the defect: an
      # earlier version said the release "is never packed" and that "nothing can
      # install this version", then acknowledged the counterexample in a trailing
      # sentence without retracting either. A definite diagnosis on the error
      # channel sends an operator after a packaging failure that may not exist.
      Castle.customize(steps: [:assemble])

      assert_received {:mix_shell, :error, [message]}

      refute message =~ "never packed"
      refute message =~ "nothing can install"

      # And the conditional is present rather than merely the claims being gone,
      # so a message that dropped the consequence entirely fails too.
      assert message =~ "No change is needed if another step creates the archive"
      assert message =~ "A deployment used only as an upgrade base needs no tarball of its own"
    end

    test "says nothing when the list has one" do
      Castle.customize(steps: [:assemble, :tar])

      refute_received {:mix_shell, :error, _}
    end

    test "says nothing about the default, which has one" do
      Castle.customize([])

      refute_received {:mix_shell, :error, _}
    end
  end

  # Bound through a function rather than compared by name: an external capture
  # of the same function is the same term, so these pin the steps that are
  # spliced in and not merely that two functions are.
  defp pre, do: &Forecastle.pre_assemble/1
  defp post, do: &Forecastle.post_assemble/1
end
