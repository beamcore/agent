defmodule Beamcore.Agent.FilesystemJournalTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.FilesystemJournal
  alias Beamcore.Agent.FilesystemJournal.Server
  alias Beamcore.Agent.Tools.{CommandRunner, Fs, Git, Modify, PathSafety}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{"MISTRAL_API_KEY" => "test-api-key"})

    root =
      Path.join(System.tmp_dir!(), "beamcore_fs_journal_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    root = PathSafety.canonical_path(root)
    previous_root = PathSafety.configure_workspace_root(root)

    session =
      Beamcore.OpenAI.client()
      |> Session.new(
        session_id: "fs-journal-#{System.unique_integer([:positive])}",
        screen_type: :agent,
        workspace_root: root
      )
      |> Map.put(:state_file, Path.join(root, ".beamcore/session.state.json"))
      |> Map.put(:checkpoint_file, Path.join(root, ".beamcore/session.checkpoints.json"))

    on_exit(fn ->
      PathSafety.restore_workspace_root(previous_root)
      File.rm_rf!(root)
    end)

    %{root: root, session: session}
  end

  test "agent modifies file and rewind restores exact bytes", %{root: root, session: session} do
    File.write!(Path.join(root, "sample.txt"), "alpha\nbeta\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "sample.txt",
      "old" => "alpha",
      "new" => "alpha changed by agent"
    })

    assert {:ok, _session} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "sample.txt")) == "alpha\nbeta\n"
  end

  test "non-overlapping human edit is preserved during rewind", %{root: root, session: session} do
    File.write!(Path.join(root, "mixed.txt"), "alpha\nbeta\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "mixed.txt",
      "old" => "alpha",
      "new" => "alpha changed by agent"
    })

    File.write!(
      Path.join(root, "mixed.txt"),
      "alpha changed by agent\nbeta\ngamma added by human\n"
    )

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "mixed.txt")) == "alpha\nbeta\ngamma added by human\n"

    restore = filesystem_restore(rewound)
    assert restore["reverted_mutations"] == 1
    assert restore["conflict_count"] == 0
  end

  test "overlapping human edit becomes conflict and current file is preserved", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "conflict.txt"), "alpha\nbeta\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "conflict.txt",
      "old" => "alpha",
      "new" => "alpha changed by agent"
    })

    File.write!(Path.join(root, "conflict.txt"), "alpha changed by human\nbeta\n")

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "conflict.txt")) == "alpha changed by human\nbeta\n"
    assert filesystem_restore(rewound)["conflict_count"] == 1
    assert Path.wildcard(Path.join(root, ".beamcore/recovery/*/current/conflict.txt")) != []
  end

  test "agent-created untouched file is removed on rewind", %{root: root, session: session} do
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "create_file",
      "path" => "created.txt",
      "content" => "agent\n"
    })

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    refute File.exists?(Path.join(root, "created.txt"))
  end

  test "agent-created file modified externally is preserved as conflict", %{
    root: root,
    session: session
  } do
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "create_file",
      "path" => "created.txt",
      "content" => "agent\n"
    })

    File.write!(Path.join(root, "created.txt"), "human\n")

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "created.txt")) == "human\n"
    assert filesystem_restore(rewound)["conflict_count"] == 1
  end

  test "agent-created directory keeps external content", %{root: root, session: session} do
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "mkdir", "path" => "generated/nested"})
    File.write!(Path.join(root, "generated/nested/human.txt"), "human\n")

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "generated/nested/human.txt")) == "human\n"
  end

  test "agent-deleted file is restored when path remains absent", %{root: root, session: session} do
    File.write!(Path.join(root, "delete_me.txt"), "original\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "remove", "path" => "delete_me.txt", "confirm" => true})

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "delete_me.txt")) == "original\n"
  end

  test "agent-deleted file does not overwrite human recreation", %{root: root, session: session} do
    File.write!(Path.join(root, "recreated.txt"), "original\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "remove", "path" => "recreated.txt", "confirm" => true})
    File.write!(Path.join(root, "recreated.txt"), "human\n")

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "recreated.txt")) == "human\n"
    assert filesystem_restore(rewound)["conflict_count"] == 1
  end

  test "agent-deleted directory is restored recursively", %{root: root, session: session} do
    File.mkdir_p!(Path.join(root, "tree/a"))
    File.write!(Path.join(root, "tree/a/file.txt"), "inside\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{
      "operation" => "remove",
      "path" => "tree",
      "recursive" => true,
      "confirm" => true
    })

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "tree/a/file.txt")) == "inside\n"
  end

  test "binary file restores exactly when untouched after agent write", %{
    root: root,
    session: session
  } do
    path = Path.join(root, "binary.bin")
    File.write!(path, <<1, 2, 3, 0, 4>>)
    checkpoint_a = checkpoint!(session, "A")

    FilesystemJournal.with_context(context(session), fn ->
      before = FilesystemJournal.file_state_from_bytes(File.read!(path), 0o644)
      File.write!(path, <<9, 0, 8, 7>>)

      assert :ok =
               FilesystemJournal.record_file_write(path, before, File.read!(path), tool: "test")
    end)

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(path) == <<1, 2, 3, 0, 4>>
  end

  test "binary external change is conflict instead of overwrite", %{root: root, session: session} do
    path = Path.join(root, "binary-conflict.bin")
    File.write!(path, <<1, 2, 3, 0, 4>>)
    checkpoint_a = checkpoint!(session, "A")

    FilesystemJournal.with_context(context(session), fn ->
      before = FilesystemJournal.file_state_from_bytes(File.read!(path), 0o644)
      File.write!(path, <<9, 0, 8, 7>>)

      assert :ok =
               FilesystemJournal.record_file_write(path, before, File.read!(path), tool: "test")
    end)

    File.write!(path, <<5, 5, 5>>)
    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(path) == <<5, 5, 5>>
    assert filesystem_restore(rewound)["conflict_count"] == 1
  end

  test "corrupted blob is detected and not restored", %{root: root, session: session} do
    path = Path.join(root, "corrupt.txt")
    File.write!(path, "original\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "remove", "path" => "corrupt.txt", "confirm" => true})
    assert not File.exists?(path)

    [blob] = Path.wildcard(Path.join(root, ".beamcore/snapshots/blobs/*"))
    File.write!(blob, "corrupted\n")

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert not File.exists?(path)

    restore = filesystem_restore(rewound)
    assert restore["status"] == "failed_recovery_required"
    assert restore["conflict_count"] == 0
    assert restore["operational_failure_count"] == 1
    assert hd(restore["operational_failures"])["reason"] =~ "corrupt blob"
  end

  test "corrupt blob preflight prevents partial multi-file restore", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "first.txt"), "first\n")
    File.write!(Path.join(root, "second.txt"), "second\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "remove", "path" => "first.txt", "confirm" => true})
    fs_agent!(session, %{"operation" => "remove", "path" => "second.txt", "confirm" => true})

    blob =
      Path.join(root, ".beamcore/snapshots/blobs")
      |> Path.join(:crypto.hash(:sha256, "second\n") |> Base.encode16(case: :lower))

    File.write!(blob, "corrupted\n")

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    refute File.exists?(Path.join(root, "first.txt"))
    refute File.exists?(Path.join(root, "second.txt"))

    restore = filesystem_restore(rewound)
    assert restore["status"] == "failed_recovery_required"
    assert restore["operational_failure_count"] == 1
  end

  test "restore coordinator runs under supervision and persists final state", %{
    root: root,
    session: session
  } do
    assert is_pid(Process.whereis(Beamcore.Agent.RestoreSupervisor))

    File.write!(Path.join(root, "owned.txt"), "base\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "owned.txt",
      "old" => "base",
      "new" => "agent"
    })

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)

    [intent] = restore_intents(root)
    assert intent["status"] == "completed"
    assert intent["result"]["status"] == "completed"
  end

  test "journal server serializes workspace transactions", %{root: root} do
    parent = self()

    first =
      Task.async(fn ->
        Server.transaction(root, fn ->
          send(parent, :first_entered)

          receive do
            :release_first -> :ok
          end

          :first_done
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        Server.transaction(root, fn ->
          send(parent, :second_entered)
          :second_done
        end)
      end)

    assert Task.yield(second, 0) == nil
    refute_received :second_entered

    send(Process.whereis(Server), :release_first)
    assert Task.await(first) == :first_done
    assert Task.await(second) == :second_done
    assert_received :second_entered
  end

  test "partial restore operational failure recovers to safety revision", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "a.txt"), "a\n")
    File.write!(Path.join(root, "b.txt"), "b\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "remove", "path" => "a.txt", "confirm" => true})
    fs_agent!(session, %{"operation" => "remove", "path" => "b.txt", "confirm" => true})

    with_restore_failure({:after_operation, 1, "injected apply failure"}, fn ->
      assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
      refute File.exists?(Path.join(root, "a.txt"))
      refute File.exists?(Path.join(root, "b.txt"))

      restore = filesystem_restore(rewound)
      assert restore["status"] == "failed_recovered"
      assert restore["operational_failure_count"] == 1
    end)
  end

  test "recovery failure is reported distinctly", %{root: root, session: session} do
    File.write!(Path.join(root, "recover.txt"), "base\n")
    checkpoint_a = checkpoint!(session, "A")
    fs_agent!(session, %{"operation" => "remove", "path" => "recover.txt", "confirm" => true})

    with_restore_failure(
      [
        {:after_operation, 1, "injected apply failure"},
        {:during_recovery, :any, "injected recovery failure"}
      ],
      fn ->
        assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
        restore = filesystem_restore(rewound)
        assert restore["status"] == "failed_recovery_required"
        assert restore["operational_failure_count"] == 1
      end
    )
  end

  test "pre-apply restore intents are cancelled safely on restart recovery", %{root: root} do
    restore_dir = Path.join(root, ".beamcore/snapshots/restores")
    File.mkdir_p!(restore_dir)

    for status <- ["planned", "preflighted", "safety_revision_saved"] do
      path = Path.join(restore_dir, "restore-#{status}.json")

      File.write!(
        path,
        Jason.encode!(%{
          "schema_version" => 1,
          "restore_id" => "restore-#{status}",
          "status" => status,
          "target_journal_position" => 1
        })
      )
    end

    assert :ok = FilesystemJournal.recover_incomplete_restores(root)

    for status <- ["planned", "preflighted", "safety_revision_saved"] do
      data =
        restore_dir
        |> Path.join("restore-#{status}.json")
        |> File.read!()
        |> Jason.decode!()

      assert data["status"] == "cancelled"
      assert data["result"]["status"] == "cancelled"
    end
  end

  test "applying restore intent recovers from safety revision on restart", %{root: root} do
    restore_id = "restore-interrupted"
    restore_dir = Path.join(root, ".beamcore/snapshots/restores")
    File.mkdir_p!(restore_dir)
    File.mkdir_p!(Path.join(root, ".beamcore/snapshots/blobs"))

    File.write!(Path.join(root, "restore.txt"), "partially restored\n")

    bytes = "pre-restore\n"
    hash = sha256(bytes)
    File.write!(Path.join(root, ".beamcore/snapshots/blobs/#{hash}"), bytes)

    safety = %{
      "schema_version" => 1,
      "restore_id" => restore_id,
      "revision_id" => "safety-test",
      "entries" => %{
        "restore.txt" => %{
          "type" => "file",
          "content_hash" => hash,
          "blob_hash" => hash,
          "byte_size" => byte_size(bytes),
          "mode" => 0o644,
          "text" => true
        },
        "created.txt" => %{"type" => "absent"}
      }
    }

    File.write!(Path.join(root, "created.txt"), "created during partial restore\n")
    File.write!(Path.join(restore_dir, "#{restore_id}.safety.json"), Jason.encode!(safety))

    path = Path.join(restore_dir, "#{restore_id}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "schema_version" => 1,
        "restore_id" => restore_id,
        "status" => "applying",
        "target_journal_position" => 1
      })
    )

    assert :ok = FilesystemJournal.recover_incomplete_restores(root)
    data = path |> File.read!() |> Jason.decode!()

    assert data["status"] == "failed_recovered"
    assert data["result"]["operational_failure_count"] == 1
    assert File.read!(Path.join(root, "restore.txt")) == "pre-restore\n"
    refute File.exists?(Path.join(root, "created.txt"))
  end

  test "BeamCore-started command mutations are journaled and selectively rewound", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "format.txt"), "alpha\nbeta\n")
    checkpoint_a = checkpoint!(session, "A")

    Application.put_env(:agent, :command_runner, fn _executable, _args, opts ->
      path = Path.join(Keyword.fetch!(opts, :cd), "format.txt")
      File.write!(path, "alpha formatted by command\nbeta\n")
      {"formatted\n", 0}
    end)

    try do
      FilesystemJournal.with_context(context(session), fn ->
        result =
          CommandRunner.run("test_tool", "test", "fake", [],
            workdir: ".",
            command_kind: "formatter"
          )

        assert result["ok"]
        assert result["filesystem_changes"]["changed_path_count"] == 1
      end)

      File.write!(
        Path.join(root, "format.txt"),
        "alpha formatted by command\nbeta\ngamma added by human\n"
      )

      assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
      assert File.read!(Path.join(root, "format.txt")) == "alpha\nbeta\ngamma added by human\n"
      assert filesystem_restore(rewound)["conflict_count"] == 0
    after
      Application.delete_env(:agent, :command_runner)
    end
  end

  test "timed out command still journals completed workspace changes", %{
    root: root,
    session: session
  } do
    checkpoint_a = checkpoint!(session, "A")

    Application.put_env(:agent, :command_runner, fn _executable, _args, opts ->
      File.write!(Path.join(Keyword.fetch!(opts, :cd), "timeout-output.txt"), "owned\n")
      Process.sleep(1_000)
      {"late\n", 0}
    end)

    try do
      FilesystemJournal.with_context(context(session), fn ->
        result =
          CommandRunner.run("test_tool", "test", "fake", [],
            workdir: ".",
            command_kind: "validation",
            timeout: 10
          )

        refute result["ok"]
      end)

      assert File.read!(Path.join(root, "timeout-output.txt")) == "owned\n"
      assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
      refute File.exists?(Path.join(root, "timeout-output.txt"))
    after
      Application.delete_env(:agent, :command_runner)
    end
  end

  test "Git hook mutations are attributed to the git command batch", %{
    root: root,
    session: session
  } do
    System.cmd("git", ["init"], cd: root, stderr_to_stdout: true)
    File.write!(Path.join(root, "tracked.txt"), "one\n")
    System.cmd("git", ["add", "tracked.txt"], cd: root, stderr_to_stdout: true)

    System.cmd(
      "git",
      [
        "-c",
        "user.name=Beamcore Test",
        "-c",
        "user.email=test@example.com",
        "commit",
        "-m",
        "initial"
      ],
      cd: root,
      stderr_to_stdout: true
    )

    hook = Path.join(root, ".git/hooks/pre-commit")
    File.write!(hook, "#!/bin/sh\nprintf 'hook owned\\n' > hook-output.txt\n")
    File.chmod!(hook, 0o755)

    checkpoint_a = checkpoint!(session, "A")
    File.write!(Path.join(root, "tracked.txt"), "two\n")

    FilesystemJournal.with_context(context(session), fn ->
      assert Git.execute(%{"operation" => "add", "path" => "tracked.txt"}) =~ "Success"
      refute Git.execute(%{"operation" => "commit", "message" => "hook mutation"}) =~ "Error:"
    end)

    assert File.read!(Path.join(root, "hook-output.txt")) == "hook owned\n"

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    refute File.exists?(Path.join(root, "hook-output.txt"))
  end

  test "executable mode is restored", %{root: root, session: session} do
    path = Path.join(root, "script")
    File.write!(path, "#!/usr/bin/env elixir\n")
    File.chmod!(path, 0o755)
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "script",
      "old" => "elixir",
      "new" => "env"
    })

    File.chmod!(path, 0o644)
    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(path) == "#!/usr/bin/env elixir\n"
    assert filesystem_restore(rewound)["conflict_count"] == 0
    assert {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o755
  end

  test "safe symlink deletion restores symlink identity", %{root: root, session: session} do
    File.write!(Path.join(root, "target.txt"), "target\n")
    File.ln_s!("target.txt", Path.join(root, "link.txt"))
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "remove", "path" => "link.txt", "confirm" => true})

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert {:ok, "target.txt"} = File.read_link(Path.join(root, "link.txt"))
  end

  test "symlink escape is rejected before deletion", %{root: root, session: session} do
    outside =
      Path.join(System.tmp_dir!(), "beamcore_outside_#{System.unique_integer([:positive])}")

    File.write!(outside, "outside\n")
    File.ln_s!(outside, Path.join(root, "escape.txt"))

    try do
      result =
        fs_agent!(session, %{"operation" => "remove", "path" => "escape.txt", "confirm" => true})

      assert result =~ "outside workspace"
      assert {:ok, ^outside} = File.read_link(Path.join(root, "escape.txt"))
    after
      File.rm(outside)
    end
  end

  test "rename is represented as delete plus create and rewinds both paths", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "old.txt"), "old\n")
    checkpoint_a = checkpoint!(session, "A")

    fs_agent!(session, %{"operation" => "move", "path" => "old.txt", "target" => "new.txt"})

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "old.txt")) == "old\n"
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "multiple agent edits are reverted in reverse order", %{root: root, session: session} do
    File.write!(Path.join(root, "multi.txt"), "alpha\nbeta\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "multi.txt",
      "old" => "alpha",
      "new" => "agent alpha"
    })

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "multi.txt",
      "old" => "beta",
      "new" => "agent beta"
    })

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "multi.txt")) == "alpha\nbeta\n"
  end

  test "human edit between two agent edits remains after rollback", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "interleaved.txt"), "alpha\nbeta\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "interleaved.txt",
      "old" => "alpha",
      "new" => "agent alpha"
    })

    File.write!(Path.join(root, "interleaved.txt"), "agent alpha\nbeta\nhuman note\n")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "interleaved.txt",
      "old" => "beta",
      "new" => "agent beta"
    })

    assert {:ok, _rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "interleaved.txt")) == "alpha\nbeta\nhuman note\n"
  end

  test "checkpoint journal boundary is exact", %{root: root, session: session} do
    File.write!(Path.join(root, "boundary.txt"), "one\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "boundary.txt",
      "old" => "one",
      "new" => "two"
    })

    checkpoint_b = checkpoint!(session, "B")

    modify_agent!(checkpoint_b.session, %{
      "operation" => "replace_exact",
      "path" => "boundary.txt",
      "old" => "two",
      "new" => "three"
    })

    assert checkpoint_a.filesystem_revision["journal_position"] == 0
    assert checkpoint_b.filesystem_revision["journal_position"] == 1

    assert {:ok, _rewound} = Session.rewind(checkpoint_b.session, checkpoint_b.id)
    assert File.read!(Path.join(root, "boundary.txt")) == "two\n"
  end

  test "fork restores selected filesystem revision without mutating old history", %{
    root: root,
    session: session
  } do
    File.write!(Path.join(root, "fork.txt"), "base\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "fork.txt",
      "old" => "base",
      "new" => "branch A"
    })

    assert {:ok, forked} = Session.fork(checkpoint_a.session, checkpoint_a.id)
    assert File.read!(Path.join(root, "fork.txt")) == "base\n"
    assert forked.branch_id != session.branch_id
    assert Enum.any?(forked.checkpoints, &(&1.id == checkpoint_a.id))
  end

  test "rollback is idempotent and unrelated files are untouched", %{root: root, session: session} do
    File.write!(Path.join(root, "owned.txt"), "base\n")
    File.write!(Path.join(root, "human.txt"), "human\n")
    checkpoint_a = checkpoint!(session, "A")

    modify_agent!(session, %{
      "operation" => "replace_exact",
      "path" => "owned.txt",
      "old" => "base",
      "new" => "agent"
    })

    assert {:ok, rewound} = Session.rewind(checkpoint_a.session, checkpoint_a.id)
    assert {:ok, _rewound_again} = Session.rewind(rewound, checkpoint_a.id)
    assert File.read!(Path.join(root, "owned.txt")) == "base\n"
    assert File.read!(Path.join(root, "human.txt")) == "human\n"
  end

  test "snapshot store is blocked from agent tools", %{session: session} do
    result =
      modify_agent!(session, %{
        "operation" => "create_file",
        "path" => ".beamcore/snapshots/blobs/nope",
        "content" => "nope\n"
      })

    refute result["ok"]
    assert result["summary"] =~ "internal snapshot"
  end

  test "oversized directory deletion is rejected before deletion", %{root: root, session: session} do
    Application.put_env(:agent, :max_directory_files, 1)

    File.mkdir_p!(Path.join(root, "large"))
    File.write!(Path.join(root, "large/a.txt"), "a")
    File.write!(Path.join(root, "large/b.txt"), "b")

    try do
      result =
        fs_agent!(session, %{
          "operation" => "remove",
          "path" => "large",
          "recursive" => true,
          "confirm" => true
        })

      assert result =~ "BEAMCORE_SNAPSHOT_MAX_DIRECTORY_FILES"
      assert File.exists?(Path.join(root, "large/a.txt"))
      assert File.exists?(Path.join(root, "large/b.txt"))
    after
      Application.delete_env(:agent, :max_directory_files)
    end
  end

  defp checkpoint!(session, label) do
    session = Session.checkpoint(session, "Checkpoint #{label}.")
    checkpoint = List.last(session.checkpoints)
    Map.put(checkpoint, :session, session)
  end

  defp modify_agent!(session, args) do
    FilesystemJournal.with_context(context(session), fn ->
      Modify.execute(args) |> Jason.decode!()
    end)
  end

  defp fs_agent!(session, args) do
    FilesystemJournal.with_context(context(session), fn ->
      Fs.execute(args)
    end)
  end

  defp context(session) do
    %{
      session_id: session.session_id,
      branch_id: session.branch_id,
      checkpoint_id: session.active_checkpoint_id,
      generation_id: "test-generation",
      workspace_root: session.workspace_root
    }
  end

  defp filesystem_restore(session) do
    session.timeline
    |> List.last()
    |> Map.get(:metadata)
    |> Map.fetch!(:filesystem_restore)
  end

  defp restore_intents(root) do
    root
    |> Path.join(".beamcore/snapshots/restores/*.json")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".safety.json"))
    |> Enum.map(fn path ->
      path
      |> File.read!()
      |> Jason.decode!()
    end)
  end

  defp with_restore_failure(failure, fun) do
    previous_enabled = Application.get_env(:agent, :enable_restore_failure_injection)
    previous_failure = Application.get_env(:agent, :filesystem_journal_restore_failure)

    Application.put_env(:agent, :enable_restore_failure_injection, true)
    Application.put_env(:agent, :filesystem_journal_restore_failure, failure)

    try do
      fun.()
    after
      restore_env(:enable_restore_failure_injection, previous_enabled)
      restore_env(:filesystem_journal_restore_failure, previous_failure)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:agent, key)
  defp restore_env(key, value), do: Application.put_env(:agent, key, value)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
