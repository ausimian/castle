# Castle

Runtime support for hot-code upgrades in Elixir releases. Castle is the runtime
half of a pair: [Forecastle](https://github.com/ausimian/forecastle) is the
build-time half. Consumers depend on Castle, which pulls Forecastle in as a
build-time dependency.

## What it does

Castle's job is configuration and release management on a running node.

- **`Castle.generate/1`** — reads `build.config` from the release's version
  directory, folds the stashed config providers over it, and writes the result
  as that version's `sys.config`. This is the whole reason the pair exists:
  Mix expands runtime configuration once, at boot, from the version it booted;
  Castle re-expands it for the version being upgraded *to*, before the relup
  runs. It is now the older of two ways to do that — see the next bullet — and
  goes away with the third step of
  [#13](https://github.com/ausimian/castle/issues/13).
- **Materialising the target's configuration**, which `install/1` and `commit/1`
  do before they hand a version to `:release_handler`. Which way depends on
  whether `releases/<vsn>/build.config` exists, and that is a sound
  discriminator because it is Forecastle that creates it: assembling a release
  today strips the providers out, stashes their initialised state under
  `:castle`, and renames the `sys.config` Mix wrote to `build.config`. So the
  file is present exactly when the configuration was intercepted at build time,
  and `Castle.generate/1` is then the only thing that can expand it. Note that
  it has to be the *presence of `build.config`* rather than the absence of
  `sys.config`: once such a release has booted once, it has both.

  When it is absent, Mix's pipeline is intact and `Castle.Peer` materialises the
  configuration instead: a `:peer` reached over a loopback socket — so no epmd,
  cookie, node name or distribution; the peer reports `nonode@nohost` and
  `is_alive() == false` — booted on the target's own `preboot` script and its
  own emulator, which runs `Config.Provider.boot/1` over the target's own
  provider modules and hands the resolved configuration back to be written.
  Castle does not fold providers itself, and must not acquire the ability to:
  the point of #13 is that Elixir's pipeline stays the only implementation of
  it. What Castle arranges is that the pipeline *writes* rather than configuring
  the VM it happens to be in, which is one field of the provider state and a
  reboot function that does nothing.

  A provider module can differ between the version that is running and the
  version being installed, which is why this cannot be done on the running
  node, and is what the peer earns.

  Six things about it are load-bearing.

  Every evaluation starts from the configuration Mix wrote, and never from the
  result of the last one. Providers are not obliged to be idempotent and the
  ones people write are not — `if System.get_env("FEATURE"), do: config …` in a
  `runtime.exs` sets a key on a run where the variable is set and says nothing
  about it on a run where it is not — so resolving over the previous result
  would leave that key behind, and the version an operator commits would be
  configured differently from the way it boots. `sys.config` cannot be the base,
  because that is the file `:release_handler` reads and so the file the resolved
  result has to land in; the first materialisation therefore copies it to
  `sys.config.pristine` and every later one seeds from there.

  That copy is staged in the working directory below, given the mode
  `sys.config` has, and published by hard link. Not written to its final name,
  and an exclusive create is not enough either: exclusivity makes *creation*
  atomic, not publication, so the file exists and is empty between the open and
  the write — long enough for a racing reader to see something that is not a
  configuration, and, if the install died there, long enough to leave a truncated
  base that every later evaluation would prefer to the original still in
  `sys.config`. A link publishes a file that is already complete, and refuses
  rather than replaces, so the loser of a race reads what the winner published
  instead of its own copy. Staging that never gets published is left where it is:
  an install cannot tell its own leftovers from another install's work in
  progress, so it does not try, and nothing reads that name. Do not "tidy up"
  stray `castle-*` names — files or directories — in code for the same reason.
  `Castle.Peer` removes the working directory *it* made, on every way out, and
  nothing else.

  **Both files this module creates are made inside an owner-only working
  directory and moved out of it, and a new one must be too.** Each holds a
  release's configuration — the base, and the scratch copy the providers resolve
  into — so none may be readable by anyone the `sys.config` it came from or is
  about to become would exclude: an operator who restricts that file has said
  something, and it has to hold for the copies.

  **The protection is the directory, not the file's own mode, and it has to be:
  OTP cannot create a file with a mode.** `:file.open/2`'s modes say how a file
  is to be read and written and nothing about the permissions it is created
  with — kernel's `mode()` type is the whole list — and an unrecognised option is
  ignored rather than refused, so `{:mode, 0o600}` is *accepted* and does
  nothing. The inode is created 0666 against the umask whichever way in you
  take. So a mode can only be applied to a file that already exists, and `chmod`
  does not revoke a descriptor somebody already holds: a reader who opened the
  path while it was 0644 goes on reading everything written afterwards. That is
  a standing read channel, not a blink, and no amount of care at the call site
  closes it. Do not go looking for an atomic create-with-mode; there isn't one.

  What works is `Castle.Peer.work_dir/1`: `mkdir` a directory in the version
  directory, chmod it 0700, and then **check that it is still empty**, refusing
  and removing it if it is not. `plan/2` is the one place the two file paths are
  decided, and it puts both inside that directory under the names they will have
  when they leave. Each is created **exclusively**, so a name already at the
  path is refused rather than followed or truncated, and each is **written
  through the handle that exclusive open returned**.

  **Never reopen a name to place content.** The exclusive open's whole value is
  that it establishes the name did not exist; closing the handle and reopening
  the same name by path throws that away, and anything able to create the name
  in between is handed the configuration. `write_private/2` therefore creates
  and fills in one movement — there is deliberately no way here to bring one of
  these files into existence without also placing its content, because
  separating the two is what let a reopen back in.

  The `chmod` is the one step that still goes by path, because OTP has nothing
  that sets a mode on an open file: `:file.change_mode/2` and
  `:file.write_file_info/2` take a name and reject a handle (`:badarg` and
  `:function_clause`). That is an accepted asymmetry rather than an oversight.
  By the time it runs the content is already committed to the inode the open
  created, so a name swapped underneath it does not receive the configuration —
  it gets narrowed, which is Castle setting some other file to 0600 inside a
  directory it verified empty and made 0700. A nuisance, not a disclosure.

  **The rule is create, narrow, then verify — and write through the handle you
  created.** The verification is not decoration and it is not defence in depth:
  it is there because five successive attempts to reason about whether a window
  was harmless were all wrong, and a sixth judgement of the same kind is worth
  nothing. Do not remove it on the grounds that you can see why the window is
  safe. That is precisely the sentence that preceded each of the previous five
  findings.

  The particular argument it replaced, so nobody reconstructs it: an empty
  directory has nothing behind the window, and permission to traverse a
  directory is checked on every lookup rather than captured at open the way
  permission to read a file is, so a stale directory descriptor grants nothing
  once the chmod has happened. Both halves are true, and both are about
  *reading*. A directory the umask left group-writable — 0002 is an ordinary
  umask and 0000 exists — can be written *into* during that window, and the child
  names are predictable, so an interloper needs no descriptor at all: it plants
  `sys.config` as a symlink to a file it can read and waits for the
  configuration to arrive through it. Empty is safe to read. It is not safe to
  write into.

  Exclusivity and privacy are separate properties and neither substitutes for
  the other. `:exclusive` on the open says nothing about the permissions the
  inode arrives with, which is why it is no answer to the paragraph above — that
  was measured, and `{:mode, _}` alongside it is silently ignored. A private
  directory says nothing about what a name already inside it would do, which is
  why it is no answer to a planted symlink: `File.write/2` follows one, truncates
  what it points at, chmods *that* to 0600, fills it with the configuration, and
  creates the target outright if the link dangles. All measured, all refused by
  `:exclusive`, which returns `:eexist` for a regular file, a symlink and a
  dangling symlink alike. `File.mkdir/1` refuses all three too, which is what
  stops the working directory's own name being taken first.

  It does not defend a version directory other accounts can write to: whoever
  can create a name there can replace `sys.config` itself, so that release is
  compromised before Castle is asked to configure it. The case defended is the
  ordinary one, a version directory anyone may traverse and read.

  `write_private/2` **refuses** to create a file in a directory that grants
  anything to group or other, rather than trusting the caller to have picked a
  path inside the working directory — the invariant is in the primitive because
  remembering it at the call sites is what failed, four times over. It is a
  guard against the next call site rather than against an attacker — a directory
  can be chmodded between the check and the create, which is the gap the
  exclusive create covers — and it also catches a filesystem that took the
  `mkdir` and ignored the `chmod`, where none of this can be honoured and the
  operator's own mode on `sys.config` would not be either.

  The file is given 0600 on creation and the model's mode **last** —
  `write_like/3` is `write_private/2` plus that, for a file written once. The
  ordering matters for the writes that come *after*, not for the first one: a
  `sys.config` at 0440 is an operator declaring their configuration read-only,
  and the scratch is written twice more after Castle creates it — the peer's
  pipeline writes the resolved configuration over it, then this module writes it
  again — with both of those reopening the name, and a file at 0440 cannot be
  reopened for writing. So the model's mode goes on last of all, immediately
  before the rename, and a failure part-way leaves the file narrower than
  intended rather than wider. Do not "simplify" the ordering back.

  **The scratch's later writes rest on the directory, not on the handle.** One of
  them is `Config.Provider.write_config!`, which is `File.write/2` in Elixir's
  own code, in the peer's VM — driving Elixir's pipeline is what this module is
  for, so that is not ours to change and must not be worked around. Nor may the
  creation handle be held open across the peer's run to cover them: the peer
  writes by name in a VM of its own, and a handle kept here would go on pointing
  at whichever inode the name had when it was opened. Elixir truncates the same
  inode today; one that wrote a temporary file and renamed it would leave the
  handle on an orphan and the configuration written through it would silently be
  nobody's. What protects those writes is that the directory was verified empty,
  is 0700, and holds only names Castle created.

  The two operations that move one of these files into place, the link that
  publishes the base and the rename that replaces `sys.config`, need permission
  on the directories rather than on the file, so a restrictive mode never has to
  be relaxed again; nor does removing what is left in the working directory
  afterwards.

  `File.write/2` creates with the process umask and never looks at a mode.
  `File.cp/2` *does* carry the mode — and was adopted here for that reason — but
  it writes the whole file first and narrows it afterwards (`:file.copy`, then
  `copy_file_mode/2` at `file.ex:1285`), which is the same exposure with a
  shorter window. The end state is identical either way, which is exactly why no
  test of the end state caught any of it. Do not add another way to write one of
  these files, and do not create one next to `sys.config` however carefully;
  extend the primitive, and put the file in the working directory.

  **Ownership and group are not reproduced — only the mode bits are.** This is a
  property of the design, not an oversight. Reproducing them needs `chown`,
  which needs privileges a release account does not have, and where Castle could
  chown it is running as root, which is a worse problem than the one being
  solved. Applying the model's numeric mode is what the operator asked for; that
  the process's default group differs from the model's is an environmental fact
  Castle cannot correct. So a deployment that restricts `sys.config` through
  group ownership — `root:secrets` at 0640, say — needs the release account's
  default group to be right for the version directory, because the base and the
  scratch will be created with that group and the mode bits will be honoured
  against it.

  `Castle.Commands.write_sys_config/2`, on the `build.config` path, is the one
  place this rule is not applied: it creates `sys.config` with the process umask
  when the file does not exist yet. There is no transient exposure there — the
  mode it is granted is the mode it keeps — and that path is deleted in step 3,
  while "nothing observable changes for a release assembled by today's
  Forecastle" pins its behaviour until then. It is a real gap, recorded rather
  than fixed here.

  A base that cannot be read as a configuration is refused, naming the remedy,
  rather than resolved from: it is preferred to `sys.config` by definition, so
  failing loudly is the only safe thing left.

  This is permanent design: the `build.config` path has always had a pristine
  base —
  `build.config` *is* one — and this is what carries that property forward when
  step 3 deletes it. It is deliberately not called `build.config`, since that
  name is the discriminator and would send the release back down the path being
  removed. `sys.config` gains a `CASTLE_MATERIALISED` comment line, which makes
  the invariant checkable: written by Castle, so a base must exist. A version
  that says that and has no base beside it is refused, with the remedy (unpack
  it again) named, rather than having a once-resolved configuration captured as
  though it were the original.

  With a pristine base, materialising at `commit` is not merely harmless but
  right: it produces what a boot at commit time would produce, which is the
  point of doing it there.

  The peer is started linked and stopped on every path out, including the
  failing ones; `wait_boot` and the call both have deadlines, so a peer that
  never answers cannot hold an install open. Everything that can refuse — a
  missing boot script, an emulator that is not there, a provider that raises, a
  compile environment that does not agree — refuses before `install_release/1`
  is called. The resolved configuration is assembled in the working directory
  and renamed onto `sys.config`, so a version never holds half a configuration.

  The control connection is a socket rather than `connection: :standard_io`,
  which is what the issue suggested. Standard IO multiplexes the peer's console
  output with the frames carrying the call over one byte stream and reserves
  sixteen byte values for the framing, every one of them a UTF-8 lead byte — so
  a provider, or a NIF under it, writing an accented character straight to a
  file descriptor fails the frame's checksum and takes the control process down,
  refusing an install that was about to succeed. Nothing outside `:peer` can
  harden that; the shared stream *is* the mechanism. The socket costs the
  diagnosis of a peer that cannot boot: a detached peer says nothing on its way
  down and the origin holds no handle on it, so a failed boot is noticed when
  the deadline expires rather than at once and with the emulator's reason. That
  was the trade, and it went the way it did because a broken release is broken
  either way while a working one must not be refused.

  Because a detached peer's descriptors are the null device, its standard error
  is relayed through its `user` process — which is what makes Elixir's account
  of a provider that raised reach the operator at all. A raw write still goes
  nowhere, which is the safe direction.

  `Castle.Peer.resolve/1` is called *in the target release*, so
  `{Castle.Peer, :resolve, 1}` is a contract between one version of Castle and
  the next. A target too old to have it fails the call and the install is
  refused.

  Finally, `Castle.Peer` makes the compile-environment check Elixir would have
  made, with Elixir's own validator. Elixir makes it in the branch that
  *applies* a resolved configuration, and again on the boot that follows the
  branch that *writes* one; this drives the writing branch and nothing boots
  afterwards, so without it a release Elixir considers unbootable would be
  installed and the problem found on the way up, where the only way out is a
  rollback. Do not weaken it into something that skips when it does not
  recognise what it was given: it refuses instead, because a check that silently
  passes everything looks exactly like a check that works.

- **`Castle.make_releases/0`** — creates the `RELEASES` file from the running
  permanent release if it does not already exist, so a release assembled by Mix
  can manage its own upgrades.
- **`unpack/1`, `install/1`, `commit/1`, `remove/1`, `releases/0`** — wrappers
  over `:release_handler`, with the target version's configuration materialised
  ahead of `install` and `commit` so that it exists before the version is
  booted.
- **`Castle.running/1`** — succeeds when the version it is given is the release
  the system is running. `install_release/1`'s reply says only that the upgrade
  was accepted: a transition that restarts the emulator is replied to and then
  rebooted, and an emulator upgrade finishes on the way back up, where it can
  still roll back. So Castle answers the question and leaves the asking to
  Forecastle: `bin/castle install` repeats it rather than trusting the reply,
  from Forecastle 1.0.0 — the revision pinned in this project's `mix.lock`
  installs with a single rpc and never calls this, so do not describe the
  polling as something Castle's own integrated state does. Two conditions. The
  version is the running release: the
  `current` one, or the `permanent` one when none is current — `install` leaves
  its target `current` and `commit` promotes it, so both count; `unpacked` (a
  rolled-back continuation) and `tmp_current` (written before the reboot) do
  not. And its boot has finished, which is `:init.get_status/0`'s *provided*
  status being `:started`. Do not gate on the internal status: it stays
  `:starting` for the life of a release started by its boot script, so a booted
  node reports `{:starting, :started}`. The provided status is what the script's
  `{progress, _}` instructions move along, and `started` is its last one — after
  the applications have started, and after `new_emulator_upgrade/2` in the
  hybrid script that continues an emulator upgrade. Without that second
  condition a poll can confirm a node that is still booting, and automation
  that commits straight after installing would make a version that cannot boot
  the permanent one.

  The marker is the whole of the evidence, so it inherits whatever the selected
  boot script does with it. `RELEASE_BOOT_SCRIPT` naming a hand-written script
  that never reaches `{progress, started}` will never be confirmed — `install`
  waits and then fails, and the refusal names the progress the node did reach,
  so it is diagnosable and never a false success — and one that emits the marker
  before its applications start defeats the check. Both are documented rather
  than validated: Mix generates the boot scripts and offers no `rel/` template
  for them, so reaching either state takes deliberate work. (An earlier note
  here claimed `systools_make:add_apply_upgrade/2`'s hard match on the trailing
  marker ruled this out. It does not: that builds the hybrid script for an
  emulator upgrade and says nothing about a script an operator supplies.)

Every one of them is a command entry point, so `Castle` is the command
boundary: an operation that fails raises `Castle.Error` there, which is what
leaves a non-zero exit status behind for the shell that asked for it. Raising,
not halting — the expression runs on the *running* node, so halting would take
down the system under management; `Kernel.CLI` catches on the node and
re-raises in the calling VM, and only that VM exits. `Castle.Commands` holds
the operations themselves, returning their outcome instead of acting on the
process, which is what makes them testable.

Forecastle is what arranges for these to be reachable: it renames `sys.config`
to `build.config` at assembly time, adds a `:preboot` script that starts
`:castle`, and writes the `env.sh` fragment and `bin/castle` wrapper that call
into this module.

## Layout

| Path | Purpose |
| --- | --- |
| `lib/castle.ex` | The command boundary: print the outcome, or raise |
| `lib/castle/commands.ex` | The commands themselves, returning their outcome |
| `lib/castle/peer.ex` | The temporary VM that runs the target's own config providers, both sides of it |
| `lib/castle/error.ex` | The exception a failed command raises |
| `test/support/` | Stubs for `:release_handler`, `:init`, the peer and config providers, plus the release-shaped tree a real peer is booted on |

## Working on this project

- Run `mix precommit` before committing. It is the single validation gate —
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`,
  `credo --strict`, `test`. Do not run the individual checks piecemeal.
- `@version` in `mix.exs` is the single source of truth for the version.
- Add user-visible changes to `RELEASE.md` on the feature branch, using
  [Keep a Changelog](https://keepachangelog.com/) sections. Do not defer release
  notes to release time, and exclude internal CI/lint churn.
- Release with `mix publisho <patch|minor|major>`, which bumps `@version`, folds
  `RELEASE.md` into `CHANGELOG.md` at the `<!-- %% CHANGELOG_ENTRIES %% -->`
  placeholder, commits and tags. Tags are bare semver — no `v` prefix. Pushing
  a tag triggers `.github/workflows/publish.yml`, which publishes to Hex.
- Never commit directly to `main`; work on a feature branch and open a PR.

## Tests

`mix test` covers `Castle.Commands` as units. `:release_handler`, `:init` and
`Castle.Peer` are reached through module arguments that default to them, so the
tests hand them `Castle.ReleaseHandlerStub`, `Castle.InitStub` and
`Castle.PeerStub` instead; `generate/1` and `materialise/2` take the version
directory they work on, so the tests give them a `tmp_dir`.
`test/castle_test.exs` drives the boundary itself against the real
`:release_handler` — which is running under `mix test`, because castle depends
on sasl — and the real `:init`, naming releases that do not exist.

`test/castle/peer_test.exs` is the exception: it starts real peers. Stubbing the
peer would prove nothing about the one thing it exists to do, which is to run a
release's *own* code. `Castle.SyntheticRelease` lays out a directory tree with
everything `Castle.Peer` needs — an emulator launcher under `erts-<vsn>/bin`,
applications under `lib/<app>-<vsn>`, a `systools` boot script over them, a
release file and a `sys.config` — so a peer boots on the same kind of script a
release ships, without a `mix release`. The test that matters most compiles two
versions of one provider module, loads one into the node running the tests and
puts the other on the peer's code path, and asserts that the answer came from
the peer's. Peer cleanup is asserted from outside: a provider records the
operating system pid of the VM it ran in, and the test waits for it to go.

It builds the **unpacked** shape by default, and the assembled one only when a
test asks for it — because the peer path is reached from `install` and `commit`,
so every version it is asked to configure was unpacked from a tarball. The two
shapes differ in the version directory's release files: Mix assembles one,
`<name>.rel`, while unpacking leaves two, that one plus the `<name>-<vsn>.rel`
`release_handler` copies in beside it. A fixture that only built the assembled
shape is how `Castle.Peer` came to refuse every unpacked release as ambiguous,
having been reviewed seven times against a directory the peer path never meets.

`Castle.Peer.materialise/2` takes `:boot_timeout` and `:resolve_timeout` for the
same reason `Castle.Commands` takes the module to talk to — a deadline nothing
can shorten is a deadline no test can show is enforced. Two tests give it a
second and assert that the refusal names it, which is what keeps the deadlines
from being a claim in a comment.

Idempotence is asserted against a control rather than against a hard-coded
expectation: two versions of the same release are built in one root, sharing a
`runtime.exs` so that the state the providers carry is identical, one is
materialised twice with the environment changing in between — install, then
commit — and the other once with the environment as it ended up. The two
`sys.config` terms have to be equal. That is why `Castle.SyntheticRelease` makes
its symlinks idempotently: a root has to be able to hold two versions.

`Castle.Peer.work_dir/1`, `secure_dir/1`, `write_like/3`, `write_private/2`,
`create_exclusive/1`, `fill/3` and `publish/2` are public for the same kind of
reason: what they guarantee is about *intermediate* states, and a window nothing
can stand in is a window nothing can test. One test takes `work_dir/1`,
`write_like/3` and `publish/2` one at a time and looks at the destination in
between — where it finds no file, rather than a partial one — then checks that
publishing again is refused rather than allowed to replace. Another calls
`work_dir/1` and finds the directory at 0700 and still empty. Call sites use
`write_private/2`; `create_exclusive/1` and `fill/3` are public only so that the
window between them can be stood in, and never to be called in sequence by
anything else.

`fill/3` being separable is what lets a test swap the name between the exclusive
open and the write, and assert that the content reached the inode that was
created while the file the name now points at never saw it — with that same test
asserting the acknowledged cost, that the by-path `chmod` does land on the
swapped name. With the name left alone the two behaviours are identical, so
there is no other way to tell them apart.

`secure_dir/1` is public so that the `mkdir`-to-`chmod` window can be stood in:
a test creates a directory at 0777, plants a `sys.config` symlink inside it, and
asserts that securing it is refused, the directory removed and what the symlink
pointed at untouched. That is the only way to observe it — nothing about the end
state distinguishes a directory that was empty when it was narrowed from one that
was not, which is what made the same mistake possible a sixth time at the
directory after five at the file. A companion test plants a name inside an
already-private directory and asserts `write_private/2` refuses it rather than
writing through it, which is the half a private directory does not cover.

Those have to be written that way. The mode a file *ends up* with is the same
whether it was set before or after the content, so a test of the end state
passes either way — which is how the exposure survived two rounds of review that
had already identified the class. The in-peer observation of the scratch file's
mode is a regression guard on the site that was wrong, not a discriminator: it
passes against a version that had the window too.

What *is* a discriminator, and what makes the exposure unreachable rather than
merely narrow, is the in-peer walk of the version directory taken while both
files exist and both hold configuration: the only thing Castle has put there is
one directory at 0700, every configuration-bearing file it made is inside that,
and the version directory itself holds nothing of Castle's but the two names it
publishes. Against the version that created those files next to `sys.config`
there is no such directory at all, so the assertion cannot pass by accident.
The other discriminator, and the reason the mode ordering cannot be reversed by
accident either, is the release whose `sys.config` is 0440: it materialises twice
and both files end at 0440, where setting the mode first fails to write the file
at all.

Two of these tests would pass for the wrong reason if written carelessly, so
they are written to fail when what they rest on moves. The compile-environment
test asserts the *refusal*, over provider state built by
`Config.Provider.init/3`: if Elixir stops representing that check as a list of
triples, `init/3` stops producing one, no refusal happens, and the test fails.
It is paired with a release whose check is satisfied, so that "refuses
everything" cannot pass for "checks correctly", and with one carrying a shape
Elixir does not produce, which has to be refused rather than skipped.

What is *not* covered here is a booted release: the upgrade of a running
system, and the exit statuses `bin/castle` returns, belong to Forecastle's
`:e2e` suite ([#8](https://github.com/ausimian/castle/issues/8)), which
exercises this code against a real release and asserts on the success messages
each command prints. Those strings — `Unpacked <vsn> ok`,
`Now running <vsn> (previously <other>).`, `Committed <vsn>. …` and the
`releases/0` table — are a contract with that suite. Failure messages are not.

## Known limitations

- **Concurrent boots race on `sys.config`.** `generate/1` writes into the
  version directory, so simultaneous `start`/`daemon`/`eval` invocations with
  differing environments overwrite each other's configuration. Do not fix this
  by letting callers choose where the configuration is written: it goes with
  `generate/1` itself, once
  [forecastle#6](https://github.com/ausimian/forecastle/issues/6) has stopped
  intercepting configuration at build time and the third step of
  [#13](https://github.com/ausimian/castle/issues/13) has deleted the path that
  reads `build.config`. The peer path does not have it — nothing boots to
  configure a target — but a boot still goes through `generate/1` until then.
- **How the materialised `sys.config` and a later cold boot of the same version
  interact is not verified yet.** Both write the same file. Materialisation
  resolves from `sys.config.pristine` and leaves no `config_provider_booted`
  marker behind, so a cold boot re-runs the providers over the materialised
  result — which is what the issue expects, and what the header Mix wrote is
  preserved for. It only becomes reachable with
  [forecastle#6](https://github.com/ausimian/forecastle/issues/6), and belongs
  there.
- **The public API is undocumented.** `@moduledoc` is still the generated
  placeholder and there are no `@doc` or `@spec` annotations
  ([#11](https://github.com/ausimian/castle/issues/11)).
- **The README is out of date.** It documents an `:appup` compiler and a
  `mix castle.relup` task that moved to Forecastle in 0.3.0, and the release
  management commands it describes on `bin/<release>` now live on `bin/castle`
  ([#9](https://github.com/ausimian/castle/issues/9)).
