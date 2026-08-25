defmodule Castle.NoMixTasksTest do
  # **Castle ships no Mix tasks.** Every build-time task lives in Forecastle,
  # whatever it is called.
  #
  # The two halves divide one job between them, and since forecastle#24 the
  # build-time tasks are named `castle.*` while still being compiled into
  # Forecastle: the namespace follows the vocabulary a developer thinks in
  # rather than the package that implements it. That leaves `Mix.Tasks.Castle.*`
  # a namespace both projects could write into, and Mix resolves a task by
  # module name alone. If both ever defined the same module, whichever `ebin`
  # came first on the code path would win - and nothing would say which, not the
  # compiler, not Mix, not the release.
  #
  # A convention nobody enforces is a convention that lapses, so it is asserted
  # here rather than remembered. That is the same move the project already makes
  # for the coverage floor, for `verify_relup!/2` and for the
  # `restart_new_emulator` refusal.
  use ExUnit.Case, async: true

  # Mix's own rule, and deliberately the same one. `Mix.Task.load_all/0` walks
  # `:code.get_path()` and matches each directory entry against
  # `Elixir.Mix.Tasks.<name>.beam` - a filename, in an `ebin`, with no reference
  # to application metadata anywhere in it.
  @task_beam ~r/^Elixir\.Mix\.Tasks\..+\.beam$/

  # A sample for the heredoc case below. `\"\"\"` is an escaped delimiter rather
  # than a nested heredoc, so `mix format` leaves it alone.
  @heredoc_sample """
  defmodule Castle.Docs do
    @moduledoc \"\"\"
    Do not do this:

        defmodule Mix.Tasks.Castle.Nope do
        end
    \"\"\"
  end
  """

  # `Application.spec(:castle, :modules)` was the obvious source here and is the
  # wrong one. `Mix.Tasks.Compile.App` fills `:modules` in with
  # `Keyword.put_new_lazy/3`, so a project that supplies its own list in
  # `application/0` *keeps* it - the metadata then says whatever that list says,
  # while Mix goes on finding every task beam in the directory regardless. The
  # metadata is a description of the artefact that something else is allowed to
  # write; the artefact is what Mix reads.
  #
  # `Mix.Project.compile_path/0` is Castle's *own* `ebin`, which is the point:
  # Castle takes Forecastle as a build-time dependency, so Forecastle's `ebin` is
  # on the code path during this very test and `Mix.Tasks.Castle.Relup` is in it.
  # That is Forecastle's and is supposed to be there. A check over the code path
  # would fail on it; this one is scoped to the only side of the collision this
  # project controls.
  test "no Mix task beam is compiled into Castle's ebin" do
    entries = File.ls!(Mix.Project.compile_path())

    # Without this the check could pass by looking at the wrong directory, or at
    # one a failed build left empty: no entries filters to no tasks, which is
    # indistinguishable from a clean result.
    assert "Elixir.Castle.beam" in entries,
           "#{Mix.Project.compile_path()} does not contain Elixir.Castle.beam, so this " <>
             "test was not looking at Castle's compiled output"

    tasks = Enum.filter(entries, &Regex.match?(@task_beam, &1))

    assert tasks == [], """
    Castle must ship no Mix tasks, and these beams are in its ebin:

    #{Enum.map_join(tasks, "\n", &"        #{&1}")}

    Mix finds a task by looking for exactly this filename on the code path, so a
    task beam here shares a namespace with the build-time tasks Forecastle
    compiles into its own ebin - which are called `castle.*` precisely because
    the name follows the user's vocabulary and not the package implementing it.
    If both projects ever define the same module, whichever ebin comes first
    wins, silently.

    Every build-time task lives in Forecastle, whatever it is called. Move this
    one there - it can keep the `castle.*` name it has.
    """
  end

  # The beam check can only see what this environment compiled, and `mix test`
  # compiles one. A module defined behind a `Mix.env()` condition would be
  # absent from that build and present in another, so the source is checked too:
  # it is the one form of the answer that does not depend on which environment
  # asked the question.
  test "no Mix task is defined in Castle's lib" do
    lib = Mix.Project.project_file() |> Path.dirname() |> Path.join("lib")
    sources = Path.wildcard(Path.join(lib, "**/*.ex"))

    assert Path.join(lib, "castle.ex") in sources,
           "#{lib} does not contain castle.ex, so this test was not looking at Castle's source"

    defined =
      Enum.flat_map(sources, fn path ->
        path |> File.read!() |> task_definitions(Path.relative_to(path, lib))
      end)

    assert defined == [], """
    Castle must ship no Mix tasks, and these are defined in its lib:

    #{Enum.map_join(defined, "\n", &"        #{&1}")}

    Every build-time task lives in Forecastle, whatever it is called. Move this
    one there - it can keep the `castle.*` name it has.
    """
  end

  # Both of these are about the detector rather than about Castle, and they are
  # here because the first version of it was a regex over lines and was wrong in
  # both directions.
  #
  # `defmodule(Mix.Tasks.Castle.Hidden)` is ordinary Elixir that `mix format`
  # preserves, and a regex anchored on whitespace after `defmodule` never saw
  # it. Wrapped in an environment branch it is invisible to the beam check too,
  # so between them the two checks reported clean on a tree that ships a task -
  # exactly the hazard this file exists to prevent.
  test "the source check sees a parenthesised definition inside an environment branch" do
    source = """
    defmodule Castle.Conditional do
      if Mix.env() == :prod do
        defmodule(Mix.Tasks.Castle.Hidden) do
          use Mix.Task
        end
      end
    end
    """

    assert task_definitions(source, "conditional.ex") == [
             "conditional.ex:3: Mix.Tasks.Castle.Hidden"
           ]
  end

  # And the other direction: relaxing that regex would have started matching
  # module-looking prose. Documentation showing what not to do is a string
  # literal rather than a definition, and the parser is what knows the
  # difference.
  test "the source check ignores module-looking text in a heredoc" do
    assert task_definitions(@heredoc_sample, "docs.ex") == []
  end

  # `Elixir.Mix.Tasks.X` names the same module as `Mix.Tasks.X` and parses with
  # an extra leading segment, which the first version of the matcher did not
  # expect. Guarded by an environment branch it was invisible to the beam check
  # too, so it escaped the pair the same way the parenthesised form did.
  test "the source check sees a fully qualified alias" do
    source = ~S"""
    if Mix.env() == :prod do
      defmodule Elixir.Mix.Tasks.Castle.Qualified do
        use Mix.Task
      end
    end
    """

    assert task_definitions(source, "qualified.ex") == [
             "qualified.ex:2: Mix.Tasks.Castle.Qualified"
           ]
  end

  # The other written form of a module name.
  test "the source check sees a literal atom module name" do
    source = ~S"""
    defmodule :"Elixir.Mix.Tasks.Castle.Atom" do
      use Mix.Task
    end
    """

    assert task_definitions(source, "atom.ex") == ["atom.ex:1: Mix.Tasks.Castle.Atom"]
  end

  # A limit, pinned so that it is a decision on the record rather than a gap
  # someone rediscovers. `alias Mix.Tasks, as: N` and then `defmodule N.Castle.X`
  # defines `Mix.Tasks.Castle.X`, and nothing short of alias resolution sees it.
  # The beam check does, for the environment it compiled - see the note on
  # `task_definitions/2` for why that is where this stops.
  test "the source check does not resolve aliases, and says so" do
    source = ~S"""
    alias Mix.Tasks, as: N

    defmodule N.Castle.Aliased do
      use Mix.Task
    end
    """

    assert task_definitions(source, "aliased.ex") == []
  end

  # Elixir's own parser rather than a pattern over the text. A `defmodule` is an
  # AST node whatever the spacing, parenthesisation or line breaks around it
  # are, and text inside a string literal is a binary in that AST rather than a
  # node - so both of the cases above fall out of asking the parser instead of
  # the characters. It matches the forms a module name is *written* in: an alias
  # (`Mix.Tasks.X`), the same alias fully qualified (`Elixir.Mix.Tasks.X`), and a
  # literal atom (`:"Elixir.Mix.Tasks.X"`).
  #
  # **What it does not do is resolve names, and that is a deliberate limit
  # rather than an oversight.** `alias Mix.Tasks, as: N` followed by
  # `defmodule N.Castle.X` names the same module and is invisible here, as are a
  # name built by `Module.concat/1`, one produced by a macro, and
  # `Module.create/3`. Resolving those means implementing alias scoping and
  # constant folding - a compiler, in a test - and the honest stopping point is
  # to say so instead.
  #
  # It costs less than it looks. The beam check is exact and cannot be fooled by
  # *any* of them, because every one still writes
  # `Elixir.Mix.Tasks.<name>.beam` into `ebin`, which is the file Mix reads. The
  # only gap the pair leaves is a module named indirectly *and* compiled only in
  # an environment `mix test` does not build, and reaching that state is not a
  # mistake anyone makes by accident - it is circumvention of an invariant this
  # file, `AGENTS.md` and `design/upgrade-tooling.md` all state in words. This
  # guards against the slip, which is someone adding `lib/mix/tasks/foo.ex`
  # because it seemed like the natural home for it.
  defp task_definitions(source, label) do
    ast =
      case Code.string_to_quoted(source) do
        {:ok, ast} -> ast
        {:error, reason} -> flunk("#{label} does not parse: #{inspect(reason)}")
      end

    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, segments} | _]} = node, acc ->
          if task_alias?(segments),
            do: {node, [{line(meta), Module.concat(segments)} | acc]},
            else: {node, acc}

        {:defmodule, meta, [module | _]} = node, acc when is_atom(module) ->
          if match?("Elixir.Mix.Tasks." <> _, Atom.to_string(module)),
            do: {node, [{line(meta), module} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
    |> Enum.reverse()
    |> Enum.map(fn {line, module} -> "#{label}:#{line}: #{inspect(module)}" end)
  end

  # `Mix.Tasks.X` parses to `[:Mix, :Tasks, :X]`, and the fully qualified
  # `Elixir.Mix.Tasks.X` to `[Elixir, :Mix, :Tasks, :X]` - the same module,
  # written twice. `Module.concat/1` already renders both as `Mix.Tasks.X`, so
  # only the recognition needs to know about the prefix.
  defp task_alias?([Elixir | rest]), do: task_alias?(rest)
  defp task_alias?([:Mix, :Tasks | _]), do: true
  defp task_alias?(_segments), do: false

  defp line(meta), do: Keyword.get(meta, :line, 0)
end
