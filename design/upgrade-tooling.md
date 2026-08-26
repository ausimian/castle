# Upgrade tooling: appups, relups, and the tasks around them

**Status:** accepted. D1 is implemented — the tasks are named `castle.*` as of
[forecastle#24](https://github.com/ausimian/forecastle/issues/24), enforced by
[castle#33](https://github.com/ausimian/castle/issues/33). The rest is
unimplemented. Supersedes nothing.
**Spans:** [ausimian/castle](https://github.com/ausimian/castle) and
[ausimian/forecastle](https://github.com/ausimian/forecastle).
**Tracked by:** [castle#32](https://github.com/ausimian/castle/issues/32).

Castle and Forecastle divide one job between them, and the work described here
crosses the boundary in both directions: a decision about what `mix` tasks are
called is settled in Castle and implemented in Forecastle, and a release option
declared through `Castle.customize/1` is honoured by a Forecastle assembly step.
Neither repository is the whole of it, so the reasoning lives here, once, and the
issues in both repositories point at it rather than restating it.

This document is the *why*. It does not describe the implementation, and it will
not be updated to track it — when it disagrees with the code, the code is right
and this should be amended or retired.

---

## 1. Where the work is today

Three things make hot upgrades harder to use than they need to be, and only the
third is cosmetic.

### 1.1 The appup is written by hand, and nothing checks it

`Mix.Tasks.Compile.Appup` takes the file named by the `:appup` project key,
evaluates it, and writes the result to `ebin/<app>.appup`. It is careful about
everything within its reach: stale output, encoding, a configured-but-missing
source. What it cannot be careful about is whether the instructions are *right*,
because it never sees a second version to compare against.

Nothing downstream closes that gap either, and the reason is worth stating
precisely. `:systools.make_relup/4` fails when an appup has no **entry** for the
from-version being upgraded from. It does not, and cannot, notice that an entry
is **incomplete**. If modules `A` and `B` both changed and the appup mentions only
`A`, `make_relup/4` produces a relup, the upgrade succeeds, `release_handler`
swaps the code path — and `B` is still the version that was loaded before, serving
calls, because nothing named it and nothing purged it. New code sits on disk,
reachable, unused. The upgrade reports success.

That is the failure this tooling exists to catch. It is invisible to the compiler,
invisible to `:systools`, invisible to `--hot`, and invisible at install time. It
becomes visible on the next restart, when the code silently changes underneath a
system nobody was upgrading.

### 1.2 The relup needs the release that has not been built yet

`Forecastle.stage_relup/1` reads the project-root `relup` during **pre**-assembly,
so the relup must exist before the build that packages it. But generating one
needs the target's `<name>.rel` and its `lib/<app>-<vsn>/ebin` directories, for the
appup lookups in `appup_file/2` — and those only exist **after** `:assemble`.

So the real workflow is:

1. `mix release` — assemble the target.
2. `mix castle.relup --target … --fromto …` — write `relup` to the project root.
3. `mix release --overwrite` — assemble it again, this time packaging the relup.

The double build is mandatory and undocumented. Worse, it makes a mutable file in
the project root the hand-off between two builds, which is why so much of the
current code is defending it: `verify_relup!/2` and its version-mismatch refusal,
the staging-file-and-rename in `publish_relup!/3`, the `on_exit` cleanup in
`Forecastle.ReleaseCase`. All of that is correct, and all of it is paying for a
seam that does not need to exist.

### 1.3 The command line is `:systools`' interface, unmodified

`--target _build/prod/rel/my_app/releases/1.1.0/my_app` is a `.rel` path with the
extension removed, from which `lib_dir/1` climbs three directories to find the
library path. It is what `:systools` wants, and it has been passed straight
through to the operator. Nobody remembers the shape, and getting it wrong
surfaces as a `:file.consult/1` error about a path.

---

## 2. Decisions

### D1. The task namespace is `castle.*`, wherever the code lives

Build-time code lives in Forecastle so it does not end up inside a runtime
release. That is a **packaging** decision. What the tasks are *called* is a
**user-interface** decision, and the two do not have to agree. Making them agree
is what produced `mix forecastle.relup`.

Nobody takes Forecastle as a dependency. Both READMEs say so outright — even the
appup-compiler-only path is documented as `{:castle, "~> 1.0", runtime: false}`.
So `forecastle.*` names a package that, by design, is in nobody's `mix.exs`. It
also splits the vocabulary in half: an operator runs `bin/castle install`, a
developer runs `mix forecastle.relup`, and the boundary between them is an
implementation detail they are being asked to learn for no return.

**Decision.** Every build-time task is named `mix castle.*` and is implemented in
Forecastle.

This is well precedented rather than novel: `phoenix_live_view` ships
`mix phx.gen.live`, and `ecto_sql` ships the `mix ecto.*` migration tasks. In both
cases the namespace follows the name the user thinks in, not the package that
implements it.

**The hazard, and how it is contained.** Mix resolves tasks by module name, so
`Mix.Tasks.Castle.Relup` compiled into Forecastle sits in a namespace Castle could
also write into. If both ever defined the same module, whichever `ebin` came first
on the code path would win, silently. So:

> **Invariant: Castle ships no Mix tasks.** Every task lives in Forecastle,
> whatever it is called.

A convention nobody enforces is a convention that lapses, so this is asserted by a
test in Castle ([castle#33](https://github.com/ausimian/castle/issues/33)) that fails the build if a `Mix.Tasks.*` module ever appears in its
own compiled output. Each task also carries one line of `@moduledoc` saying it is
provided by Forecastle, so a stack trace or `mix help castle.relup` does not read
as a mystery.

**Timing.** This lands in 1.0.0
([forecastle#24](https://github.com/ausimian/forecastle/issues/24)). Castle is at 0.3.1 and Forecastle at 0.1.3, so
the cost of getting it right is zero now and permanent afterwards. No compatibility
alias: a shim for a package documented as not directly depended upon is code
maintained forever for a user who does not exist.

It also gives [castle#9](https://github.com/ausimian/castle/issues/9) a better
resolution than the one it asks for. That issue is that the README documents
`mix castle.relup` and an appup compiler that no longer live in Castle; the
assumed fix was to correct the README to say `forecastle.*`. Renaming instead
makes the README correct as written, plus one sentence about where the tasks come
from.

`mix compile.appup` is unaffected — it is named by its `:compilers` entry, not by
a package.

### D2. Appups stay source, and nothing generates them during assembly

`Mix.Tasks.Compile.Appup`'s entire moduledoc is about not shipping upgrade
instructions that belong to some other version of the code. Synthesising an appup
during assembly would reintroduce exactly that, one level up: the release would
carry instructions nobody read, derived from a comparison nobody saw.

**Decision.** Generation is an explicit act a person invokes, and it writes a
source file they review and commit. The `:appup` compiler is unchanged, and
`appup.exs` remains the single source of truth.

### D3. The coverage check is the primary artefact; the generator falls out of it

Given the machinery to diff two builds of an application, two things become
possible. Only one of them is trustworthy on its own.

**The check is trustworthy.** "This module's code changed and no instruction in
the appup mentions it" is a near-certain bug, stated without guessing at anything.
Three questions it answers, all of them decidable:

- changed and mentioned in no instruction → the §1.1 failure
- mentioned but unchanged → usually a leftover naming the wrong module
- added or removed and unmentioned → a missing `add_module` / `delete_module`

Two details make it exact rather than approximate. From-versions are matched with
`:systools_relup.appup_search_for_version/2` — the function `systools` and
`release_handler` both use, which the relup task already calls, so the check and
`auto` cannot disagree, and a regex from-version resolves identically. And an edge
whose script ends in `restart_emulator` needs no coverage at all: module-level
instructions are moot when the emulator is going to be replaced.

**The generator is a draft.** It answers *which modules moved*, which is tedious
and error-prone for a person. It must not pretend to answer *what happens to the
state*, which only the author knows. §3 sets out exactly where that line falls.

**Decision.** Build the check first and make it the CI gate. The generator is
built on top of it and is understood to produce something a person edits.

The check does **not** belong in `mix precommit`: it needs a baseline, which
precommit has not got. It is a release-pipeline gate.

### D4. Baselines are named by an explicit spec, and the tarball is the honest one

Both the check and the relup task need a *baseline* — a previous version to
compare against. Three sources, one grammar, no sniffing:

```
rel:_build/prod/rel/my_app/releases/1.0.0/my_app   # an assembled release
tar:artifacts/my_app-1.0.0.tar.gz                  # a shipped artefact
ref:v1.0.0                                         # a git ref, built in a worktree
```

A bare path stays `rel:`, so the existing `--fromto`/`--upfrom`/`--downto`
switches keep working unchanged. Direction stays on the switch name and source
stays in the value; crossing them into separate switches would be twelve of them.

**`tar:` is the recommended source, and the reason is correctness rather than
convenience.** `release_handler` selects a relup entry by from-version *string*.
It never verifies that the code actually running matches what the relup assumed.
Rebuild an old tag today and you get today's Elixir and OTP patch releases,
today's hex tarballs for anything not fully pinned, today's compiler output. If
the resulting module set differs at all from what is deployed, the instructions
miss modules — and that is the §1.1 failure again, arrived at from the other
direction. A relup generated against a rebuilt baseline describes a transition
from a release that never existed.

**`ref:` is genuinely useful and genuinely second best.** It is right for
development, for testing the upgrade path, and for the common case where nobody
kept the artefact. It must say what it is: a rebuilt baseline, not the deployed
one.

Things `ref:` has to get right, in a project laid out as a bare repository with
linked worktrees:

- **Cache by resolved sha**, artefacts under `_build/castle/baselines/<sha>` with
  `MIX_BUILD_ROOT` set per baseline. `Forecastle.Fixture` already uses exactly
  this trick, for exactly this reason.
- **Keep the worktree out of the tracked tree.** `Forecastle.Fixture`'s moduledoc
  has already learned this one: artefacts inside the project get picked up by the
  formatter and by `mix test`. Remove the worktree once the build is done, keep
  the artefacts, and `git worktree prune`.
- **Guard against recursion.** Building the old ref runs *its* `mix.exs`, which
  calls `Castle.customize/1`, which may itself want to generate a relup.
- **Shallow clones.** CI clones with `--depth 1` constantly and the tag will not
  be in the object store. Detect it and say `git fetch --tags --unshallow` rather
  than letting `git worktree add` fail obscurely.
- **Old refs often do not build today** — yanked dependencies, deprecations that
  became errors. Another reason `tar:` is the default answer.

The appup check needs only `mix compile` in the worktree; the relup task needs
`mix release`. That is a large cost difference and the resolver should expose
both.

`git archive <ref> | tar -x` is a legitimate lighter alternative to
`git worktree add` — the build needs no `.git`, since `@version` here comes from a
module attribute rather than `git describe`. Worktrees are chosen for familiarity
in a repository already laid out that way, not because the alternative is unsound.

### D5. The relup is generated during assembly

At the point between `post_assemble` and `:tar`, `release.version_path` exists,
`<name>.rel` has been written, and `lib/` is populated — everything
`systools_plan!/3` needs. So the relup can be generated there and written straight
into the version path.

**Decision** ([castle#34](https://github.com/ausimian/castle/issues/34),
[forecastle#28](https://github.com/ausimian/forecastle/issues/28)).
`Castle.customize/1` grows an `upgrade_from:` option naming one or more baselines. When it is set, a step between `post_assemble` and `:tar`
generates the relup for this exact target. The double build in §1.2 disappears,
and the target path is never typed.

The project-root `relup` stays supported for hand-written plans, along with
`verify_relup!/2`. Both present at once is a refusal, not a precedence rule.

**No `mix castle.upgrade` task.** Once this is a release step, a whole-edge task
would be `mix release` with extra syllables. The best tooling here is one fewer
command. `mix castle.relup` still covers what the step cannot reach: two artefacts
that already exist, with no rebuild.

**One tension, accepted.** With `ref:`, an ordinary `mix release` now triggers a
minutes-long build of a previous version as a side effect. It is opt-in and `tar:`
is fast, so it stands — but it is the trigger that would justify a
`mix castle.baseline <spec>` task, purely so CI can run the expensive resolution
as its own cacheable, separately-logged stage. Deferred, with the cache path
documented so CI can cache the directory without one.

### D6. What we deliberately do not do

- **Generate appups during assembly.** D2.
- **Infer the baseline when the spec is ambiguous.** The failure mode of a wrong
  guess is a silently wrong upgrade plan.
- **Compute the `Extra` term for `code_change/3`.** Not derivable. §3.
- **Chase `restart_new_emulator`.** Unchanged from today: Castle is built for the
  one-stage transition and refuses the two-stage one wherever it appears.
- **Ship a `mix castle.upgrade.test` task.** The upgrade harness wants to be an
  `ExUnit.CaseTemplate` plus `Forecastle.Deployment`, run by `mix test`. A task
  would have to hardcode what "the upgrade worked" means, and only the project
  knows that. It ships cleanly too — Forecastle is already `runtime: false`, so
  the harness is available at build and test time and never enters a release.
- **Ship a `mix castle.init`.** Four lines of copy-paste from the README, and the
  useful half is `mix.exs` AST rewriting nobody wants. `mix release.init` avoids
  the same problem by only writing `rel/*` templates.

---

## 3. What a beam diff can and cannot know

These were measured on Elixir 1.19.5 / OTP 28 rather than assumed, because the
whole design rests on them.

### 3.1 Change detection: `:beam_lib.md5/1`, not a file digest

`Mix.Release.strip_beam/2` rebuilds each beam from
`@additional_chunks ++ :beam_lib.significant_chunks()`, where
`@additional_chunks` is `~w(Attr)c`. Measured, for a module before and after that
call:

```
before: AtU8 Code StrT ImpT ExpT FunT LitT LocT Attr CInf Dbgi Docs ExCk Line Type
after:  Attr Line Type AtU8 Code StrT ImpT ExpT FunT LitT
```

So `Dbgi`, `Docs`, `CInf` and `ExCk` are gone from a release's beams — no abstract
code, no documentation chunk — while `Attr` survives, and with it the `vsn` and
`behaviour` attributes.

`:beam_lib.md5/1` is **stable across that stripping** (verified), so it compares a
`_build` beam against a release's copy of the same code correctly. A digest of the
file bytes does not, and would report every module as changed. Use
`:beam_lib.md5/1`.

**A trap worth naming:** raw `:beam_lib.strip/1` — the obvious function — drops
`Attr`. Mix does not use it, and neither should this.

### 3.2 `code_change/3` is not a signal

An earlier draft of this design classified modules by whether they export
`code_change/3`, on the reasoning that modern `use GenServer` no longer injects
one. That is false. Elixir 1.19.5's `gen_server.ex:953` injects an overridable
`@doc false def code_change(_old, state, _extra), do: {:ok, state}`. **Every**
`use GenServer` module exports `code_change/3`, so its presence says nothing.

Nor can the injected default be told from a hand-written one at a release's beams:
distinguishing them would need the `Docs` chunk (`:hidden` versus `:none`) or the
abstract code, and §3.1 shows both are stripped.

### 3.3 The decision table

Behaviours are the only signal, read from `Attr`, and that turns out to be enough
— because `{:advanced, []}` is safe whether or not a `code_change/3` was written.
Worst case the injected identity runs, and the instruction costs a suspend.
`{:update, M}` (soft) is the unsafe one: it does not call `code_change/3` at all,
so a state that did need migrating is silently left alone.

| Signal in `Attr` | Instruction |
| --- | --- |
| `Supervisor` / `:supervisor` | `{:update, M, :supervisor}` |
| `GenServer` / `:gen_server` / `:gen_statem` / `:gen_event` / `:gen_fsm` | `{:update, M, {:advanced, []}}` |
| anything else | `{:load_module, M}` |
| absent from the baseline | `{:add_module, M}` |
| absent from the target | `{:delete_module, M}` |

Both spellings must be handled: Elixir modules carry `behaviour: [GenServer]`,
Erlang ones `behaviour: [:gen_server]` (measured: `Mix.State` → `[GenServer]`,
`:logger_std_h` → `[:logger_handler]`).

### 3.4 What the generator must say rather than decide

Emitted as comments beside the instructions, because a draft that hides its
uncertainty is worse than no draft:

- **The `Extra` term is always `[]`.** Nothing can derive it.
- **`{:update, M, :supervisor}` re-reads `init/1` and reconciles child *specs*.**
  It does not upgrade the children. Those need their own instructions.
- **`update` only reaches processes found through the supervision tree.** A
  process nobody supervises keeps its old code, silently, and the appup will look
  as though it covered it.
- **Ordering is not solved.** `add_module` before its users, `delete_module`
  after. `DepMods` between changed modules is derivable from import tables and
  may be added later; until then the order is stable, not correct.

### 3.5 Pinning §1.1 with a test ([forecastle#25](https://github.com/ausimian/forecastle/issues/25))

The stale-code failure is stated in this document as a mechanism, not as something
that has been demonstrated here. It should be pinned by a test before the check is
built on top of it, and the fixture is already shaped for it: `Sample.Counter`
carries a compile-time `@vsn_tag` that is observable from outside the running
system. A deliberately incomplete appup, an upgrade that reports success, and an
assertion that the unmentioned module still answers with the old tag would settle
it. If it turns out not to reproduce, D3 needs revisiting before anything is
built.

---

## 4. The task surface

| Task | Status | Purpose |
| --- | --- | --- |
| `mix compile.appup` | unchanged | The `:appup` compiler. Source → `ebin/<app>.appup`. |
| `mix castle.relup` | renamed, extended | Generate a relup. Spec-prefixed baselines; `--dry-run`. |
| `mix castle.appup` | new | Read-only. Module diff and appup coverage. Non-zero on gaps. |
| `mix castle.appup.gen` | new | Writes or merges the suggested appup entry. |

### `mix castle.appup`

```
mix castle.appup --from <spec> [--to <spec>] [--app <app>]...
```

Read-only. `--to` defaults to the **current build** (`_build/<env>/lib/<app>/ebin`)
rather than an assembled release, so the everyday question — *what has changed
since 1.0.0, and does my appup cover it?* — needs only `mix compile`. `--app`
defaults to the project's own applications plus umbrella children, which
`project_apps/0` already computes; naming a dependency explicitly is how the
dependency-appup case is reached. Exits non-zero when a changed module is
mentioned nowhere.

### `mix castle.appup.gen`

Same inputs, plus writing. `.gen.` is the established Elixir idiom for *this
writes source you will review and commit*, which is exactly D2's semantics. Four
cases, the first three for an application this project owns:

- no appup yet → write `appup.exs`
- an existing appup whose AST is a pure literal → merge the new from-version
  entry, print the diff
- an existing appup that computes → refuse to write, print the entry to merge by
  hand
- `--app <dep>`, an application this project does *not* own → write
  `rel/appups/<dep>-<from>-<to>.exs`, which §5.5 is about and §6's *Settled*
  records the reasoning for

The third case is why this is safe. An appup is arbitrary evaluated Elixir — the
fixture's own is a `case` on `SAMPLE_VSN` — and flattening one into a static term
would silently discard its logic. `Code.string_to_quoted/1` makes "is this a pure
literal?" decidable, so the refusal is exact rather than heuristic.

### `mix castle.relup --dry-run`

Nearly free, because `auto` already cannot announce its verdict until after
generation — `settle_restarts!/2` runs on the generated plan, for reasons the task
documents at length. So `--dry-run` is: generate in memory, classify, announce,
write nothing. It answers *can 1.0.0 → 1.1.0 be hot, and if not, which edge and
why* before any appups are written.

`--dry-run` rather than `--explain`: the conventional meaning is exactly right,
and `--explain` would imply the classification is not already printed on an
ordinary run, which it is.

### Deferred

- `mix castle.baseline <spec>` — see D5.
- Cache cleanup. Once `_build/castle/baselines/` exists it needs clearing, and
  the recovery instruction should not be "delete a path you have to go and look
  up". A separate task, not a `--clean` flag on something that generates. Named
  for what it clears — `mix castle.baseline.clean` — because `mix castle.clean`
  reads as though it might touch a release.

---

## 5. Sequencing

Nothing new in 1.0.0 **except D1**, the rename, which has to be now or never.
Both repositories have real open issues against the current release and this is
all additive surface.

Then, in dependency order:

1. **The baseline resolver** (`rel:`, `tar:`, `ref:`) — [forecastle#26](https://github.com/ausimian/forecastle/issues/26) — small, testable, and the
   enabler for everything else. Wire `tar:` and `rel:` into `mix castle.relup`
   first; `ref:` after.
2. **`mix castle.appup`** — [forecastle#27](https://github.com/ausimian/forecastle/issues/27). The check. Highest value per line of code, and §3.5
   comes with it.
3. **Relup generation during assembly** — [castle#34](https://github.com/ausimian/castle/issues/34) and [forecastle#28](https://github.com/ausimian/forecastle/issues/28). `Castle.customize(upgrade_from: …)`.
   A contract change, so it carries its own issue in each repository.
4. **`mix castle.appup.gen`** — [forecastle#29](https://github.com/ausimian/forecastle/issues/29). The generator, the literal-only merge, the
   comments from §3.4.
5. **Dependency appups** ([forecastle#30](https://github.com/ausimian/forecastle/issues/30)). Most Elixir hot upgrades die because a dependency bumped
   a patch version and has no appup, so `auto` degrades the whole edge to a
   restart. The design already anticipates the fix: `appup_gap/4` deliberately
   reads the *target release's* copy of a dependency's appup and honours a
   matching entry whoever wrote it. What is missing is a project-owned place to
   put them (`rel/appups/<dep>-<from>-<to>.exs`) and a post-assembly step to place
   them into `lib/<dep>-<vsn>/ebin/`. Never into `deps/`.
6. **`--dry-run`** ([forecastle#31](https://github.com/ausimian/forecastle/issues/31))**, then the upgrade harness** ([forecastle#32](https://github.com/ausimian/forecastle/issues/32))**.** The harness is the largest piece and
   has the highest ceiling: `Forecastle.Deployment` and the upgrade suites already
   assemble two versions, start one, install the other and assert the state
   survived. Extracted so downstream projects can point it at their own release,
   it is what makes hot upgrades safe to *adopt* rather than merely possible.

---

## 6. Open questions

- **`DepMods` ordering.** Derivable from the changed modules' import tables.
  Worth it, or noise?
- **Should this document ship to hexdocs?** It would need adding to `docs/0`'s
  `extras:` and to `package/0`'s `files:`, which currently ships only
  `lib CHANGELOG.md LICENSE mix.exs README.md .formatter.exs`. The user-facing
  half is worth publishing; the decision records probably are not.

### Settled

Kept here rather than deleted, because what a question turned out to rest on is
worth as much as the answer to it.

- **Does §1.1 reproduce?** Yes, and it is pinned —
  [forecastle#25](https://github.com/ausimian/forecastle/issues/25), §3.5.
  `upgrade_test.exs` carries a `Sample.Unmentioned` module that changes across
  the transition and that no instruction mentions, and it asserts *both* halves
  of the failure: the running process still answering from the from-version, and
  the new code sitting on disk, reachable through `:code.get_object_code/1` and
  unused. An assertion about the process alone cannot show the second, which is
  the half that makes it a silent failure rather than a visible one. Everything
  in D3 rests on this, and it holds.

- **Where does the dependency-appup source live**, and does `mix castle.appup.gen`
  write there directly or print for review as it does for owned applications?
  `rel/appups/<app>-<from>-<to>.exs`, and it **writes** —
  [forecastle#30](https://github.com/ausimian/forecastle/issues/30), §5.5.

  **The argument is in what the refusal it replaced actually said**: *"a
  dependency has no source here to write"* — an observation about a missing
  destination, not a policy about dependencies. `rel/appups` is that
  destination, so the premise is gone. Consistency then argues the same way
  round rather than against: for an owned application the task writes, so
  printing for a dependency would leave the merge case dead and a
  copy-this-out-of-your-terminal workflow beside the good one.

  D2 is satisfied identically — the output is source a person reviews and
  commits, nothing generates an appup during assembly, and assembly places a
  file somebody wrote after checking its name still describes the transition.
  The safety story is in fact *stronger* than for `appup.exs`: a dependency file
  is named for one transition, so the build refuses it by name the moment the
  dependency moves on, where a drifted tag in `appup.exs` is only a `bad_vsn`
  note.
