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
  # asked only whether `:steps` was present, or whether the Castle steps
  # appeared in it, would pass against a splice that put them the wrong side of
  # `:assemble` - and the wrong side is the only way to get this wrong, since
  # `pre_assemble/1` prepares what `:assemble` writes and `post_assemble/1`
  # reads what it wrote.
  #
  # There are three of them rather than two, and the third is `relup/0`:
  # `Forecastle.steps/1` also puts `generate_relup/1` immediately before `:tar`,
  # which is the one point in a build where everything `:systools` needs exists
  # and nothing has been packed yet. It is in every list this produces, whether
  # or not the release names a baseline to upgrade from - see the
  # `upgrade_from:` cases at the foot of this file for what it does with
  # neither.
  describe "customize/1" do
    test "puts the Castle steps either side of :assemble, and the relup before :tar" do
      assert Castle.customize(steps: [:assemble, :tar]) ==
               [steps: [pre(), :assemble, post(), relup(), :tar]]
    end

    # Not just that they survive, but that they stay where they were: a project
    # writes a step before `:assemble` because it has to run before the release
    # is written, and one after because it has to run on what was written.
    #
    # The relup step goes after the project's own post-assembly steps and not
    # merely after `post_assemble/1`, which is Forecastle's decision and is
    # pinned here because it is Castle's `@doc` that promises it: a function
    # step between `:assemble` and `:tar` is Mix's documented way to change an
    # assembled release, so generating the relup before one would describe a
    # tree that `:tar` then packs differently.
    test "keeps the project's own steps, and their order" do
      own_pre = fn release -> release end
      own_post = fn release -> release end

      assert Castle.customize(steps: [own_pre, :assemble, own_post, :tar]) ==
               [steps: [own_pre, pre(), :assemble, post(), own_post, relup(), :tar]]
    end

    # `:steps` absent is the case a project reaches by saying nothing, so the
    # default is what most releases will be built with. It is Mix's default plus
    # `:tar`: see the @doc, and the missing-`:tar` cases below.
    test "defaults :steps to Mix's own plus :tar when there is none" do
      assert Castle.customize([]) == [steps: [pre(), :assemble, post(), relup(), :tar]]
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
      assert customized[:steps] == [pre(), :assemble, post(), relup(), :tar]
    end

    test "adds :steps without disturbing the options that were there" do
      assert Castle.customize(include_executables_for: [:unix]) ==
               [
                 include_executables_for: [:unix],
                 steps: [pre(), :assemble, post(), relup(), :tar]
               ]
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
    # The relup step is appended rather than dropped: with no `:tar` there is no
    # packing step for it to precede, so it goes last and describes the finished
    # tree. `Forecastle.steps/1` owns that, and it is asserted here because the
    # whole list is what these cases assert.
    test "honours the list as it stands" do
      assert Castle.customize(steps: [:assemble]) == [steps: [pre(), :assemble, post(), relup()]]
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

  # **`customize/1` does not know `upgrade_from:` exists, and that is the whole
  # of Castle's half of castle#34.** Mix keeps every release option it does not
  # recognise in `%Mix.Release{}.options` - "a keyword list with all other user
  # supplied release options", in `Mix.Release`'s own words - so an option named
  # in `mix.exs` reaches `Forecastle.generate_relup/1` without anything here
  # carrying it. What Castle contributes is the *step* that reads it, which
  # `Forecastle.steps/1` splices in and the cases above pin.
  #
  # So these assert a non-event, and they are worth the space because the
  # obvious reading of the issue title is that `customize/1` grows a parameter
  # of its own. Every one of Forecastle's refusals below is about the *shape* of
  # the value as the project wrote it, so a `customize/1` that normalised,
  # defaulted, wrapped or deduplicated the option would turn a refusal into a
  # build that generated an upgrade plan nobody asked for - which is the failure
  # this whole tree exists to remove.
  describe "customize/1 and the upgrade_from: release option" do
    test "passes one baseline through untouched" do
      assert Castle.customize(upgrade_from: ["tar:artifacts/my_app-1.0.0.tar.gz"]) ==
               [
                 upgrade_from: ["tar:artifacts/my_app-1.0.0.tar.gz"],
                 steps: [pre(), :assemble, post(), relup(), :tar]
               ]

      refute_received {:mix_shell, :error, _}
    end

    # Several baselines are one option, and the list is the project's: not
    # sorted, not deduplicated, not rewritten from one grammar into another.
    # `Forecastle.Relup.generate!/6` builds a transition for each of them in the
    # order given, so reordering here would reorder the relup.
    test "passes several baselines through, in order" do
      specs = [
        "tar:artifacts/my_app-1.0.0.tar.gz",
        "rel:_build/prod/rel/my_app/releases/1.1.0/my_app",
        "ref:1.2.0"
      ]

      assert Castle.customize(upgrade_from: specs) ==
               [upgrade_from: specs, steps: [pre(), :assemble, post(), relup(), :tar]]

      refute_received {:mix_shell, :error, _}
    end

    # The other half of "omitting it leaves assembly exactly as it is today":
    # `customize/1` adds no `upgrade_from:` of its own, so a release that says
    # nothing about upgrading has nothing said about it. A default of `[]` here
    # would be the worst of both - Forecastle refuses an empty list, so every
    # release that had never heard of the option would stop assembling.
    test "adds no upgrade_from: when the release names none" do
      refute Keyword.has_key?(Castle.customize([]), :upgrade_from)
      refute Keyword.has_key?(Castle.customize(include_executables_for: [:unix]), :upgrade_from)
    end

    # **The load-bearing one.** `customize/1` is `Keyword.update/4` over
    # `:steps`, and `Keyword.update/4` deletes later duplicates *of the key it
    # updates* and leaves every other key alone - including duplicates of it. So
    # a definition assembled by joining lists, which is how a release option is
    # most naturally added alongside others, carries both occurrences through to
    # `Keyword.get_values/2` in Forecastle, which refuses rather than taking the
    # first and discarding the rest.
    #
    # Asserted as `get_values/2` rather than as the whole list because that is
    # the function whose answer decides the refusal: a `customize/1` that
    # collapsed the two would leave a build generating a plan against baselines
    # the project never settled on, with nothing said about the ones dropped.
    test "keeps a repeated upgrade_from:, both of them" do
      customized =
        Castle.customize(upgrade_from: ["tar:a.tar.gz"], upgrade_from: ["tar:b.tar.gz"])

      assert Keyword.get_values(customized, :upgrade_from) ==
               [["tar:a.tar.gz"], ["tar:b.tar.gz"]]
    end

    # An empty list and a malformed value are handed on exactly as written, for
    # the reason a `:steps` value that is not a list is: the refusal belongs to
    # whoever documents the grammar, and a second one here would be a second
    # wording of the same rule, free to drift from it. The cases below then show
    # that the refusal is real rather than assumed.
    test "passes an empty or malformed upgrade_from: through without a word" do
      assert Castle.customize(upgrade_from: [])[:upgrade_from] == []
      assert Castle.customize(upgrade_from: "tar:a.tar.gz")[:upgrade_from] == "tar:a.tar.gz"
      assert Castle.customize(upgrade_from: [:tar])[:upgrade_from] == [:tar]
      assert Castle.customize(upgrade_from: ["nope:a"])[:upgrade_from] == ["nope:a"]

      refute_received {:mix_shell, :error, _}
    end
  end

  # **Castle validates none of this, and these cases are what stops that being a
  # sentence nobody checked.** The README and `customize/1`'s `@doc` both say
  # `upgrade_from:` is refused when it is empty, malformed or repeated, and
  # neither Castle's code nor Castle's suite would notice if Forecastle stopped
  # refusing - the option would simply be carried into a build that generated no
  # relup and said nothing, which is precisely the shape of defect this tree has
  # been finding. So the step `customize/1` splices in is run over the options
  # `customize/1` produced, and the refusal is asserted where the documentation
  # claims one.
  #
  # What is asserted is that a `Mix.Error` is raised and that its message names
  # what the project wrote - the option, or the spec, depending on which of the
  # two refuses. The wording is Forecastle's to change and is deliberately not
  # restated here.
  #
  # **The two are not interchangeable and the difference is measured rather than
  # assumed.** The shape refusals come from `Forecastle`'s own reading of the
  # option and name `upgrade_from:`; the *grammar* refusal comes from
  # `Forecastle.Baseline.parse!/1`, which is shared with `mix castle.relup`'s
  # `--fromto`/`--upfrom`/`--downto` switches and so names the spec it could not
  # parse instead. Asserting the option name on that one fails, which is how
  # this comment came to be here rather than a guess.
  #
  # Every one of these refusals happens in `generate_relup/1`'s first expression,
  # before it looks for a hand-written relup or asks `:systools` for anything, so
  # none of this touches the filesystem and the file stays as free of machinery
  # as the rest of it. A *valid* `upgrade_from:` is deliberately not run: that
  # one goes on to resolve baselines and write a relup, which is Forecastle's to
  # test and needs a release to do it against.
  describe "the relup step customize/1 splices in" do
    test "does nothing at all when the release names no baseline" do
      release = release([])

      assert relup().(release) == release
    end

    test "refuses an empty list of baselines" do
      assert_upgrade_from_refusal(upgrade_from: [])
    end

    test "refuses a value that is not a list" do
      assert_upgrade_from_refusal(upgrade_from: "tar:artifacts/my_app-1.0.0.tar.gz")
    end

    test "refuses a baseline that is not a string" do
      assert_upgrade_from_refusal(upgrade_from: [:tar])
    end

    # The one that names the spec rather than the option - see above. Asserted
    # on the spec so that the case still says what an author would search for.
    test "refuses a spec whose prefix names no source" do
      error =
        assert_raise Mix.Error, fn ->
          relup().(release(upgrade_from: ["nope:artifacts/my_app-1.0.0.tar.gz"]))
        end

      assert Exception.message(error) =~ "nope:artifacts/my_app-1.0.0.tar.gz"
    end

    test "refuses a repeated upgrade_from:" do
      assert_upgrade_from_refusal(upgrade_from: ["tar:a.tar.gz"], upgrade_from: ["tar:b.tar.gz"])
    end
  end

  # The options half of what `customize/1` returned, in the struct Mix would
  # have built from it. `:steps` is dropped because Mix pops it into its own
  # field rather than leaving it in `:options`, which is the list the step
  # reads.
  defp release(opts) do
    options = opts |> Castle.customize() |> Keyword.delete(:steps)

    struct!(Mix.Release, options: options)
  end

  defp assert_upgrade_from_refusal(opts) do
    error = assert_raise Mix.Error, fn -> relup().(release(opts)) end

    assert Exception.message(error) =~ "upgrade_from:"
  end

  # Bound through a function rather than compared by name: an external capture
  # of the same function is the same term, so these pin the steps that are
  # spliced in and not merely that three functions are.
  defp pre, do: &Forecastle.pre_assemble/1
  defp post, do: &Forecastle.post_assemble/1
  defp relup, do: &Forecastle.generate_relup/1
end
