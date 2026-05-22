defmodule Beamcore.Agent.Tools.FsTest do
  use ExUnit.Case
  require Beamcore.Agent.Tools.Fs

  test "fs tool exist operation returns true for existing path" do
    File.mkdir_p!("test_fs_dir")

    try do
      result = Beamcore.Agent.Tools.Fs.execute(%{"operation" => "exist", "path" => "test_fs_dir"})
      assert result == "true"
    after
      File.rm_rf!("test_fs_dir")
    end
  end

  test "fs tool exist operation returns false for non-existing path" do
    result =
      Beamcore.Agent.Tools.Fs.execute(%{
        "operation" => "exist",
        "path" => "non_existent_path_12345"
      })

    assert result == "false"
  end

  test "fs tool stat operation returns file info" do
    File.mkdir_p!("test_fs_dir")

    try do
      result = Beamcore.Agent.Tools.Fs.execute(%{"operation" => "stat", "path" => "test_fs_dir"})
      assert String.contains?(result, "Path: ")
      assert String.contains?(result, "Type: directory")
      assert String.contains?(result, "Size: ")
    after
      File.rm_rf!("test_fs_dir")
    end
  end

  test "fs tool touch operation creates file" do
    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "touch",
          "path" => "test_fs_touch_12345.txt"
        })

      assert String.contains?(result, "Successfully touched")
      assert File.exists?("test_fs_touch_12345.txt")
    after
      File.rm_rf!("test_fs_touch_12345.txt")
    end
  end

  test "fs tool copy operation copies file" do
    File.mkdir_p!("test_fs_dir")
    File.write!("test_fs_dir/test_file.txt", "test content")

    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "copy",
          "path" => "test_fs_dir/test_file.txt",
          "target" => "test_fs_copy_12345"
        })

      assert String.contains?(result, "Successfully copied")
      assert File.exists?("test_fs_copy_12345")
    after
      File.rm_rf!("test_fs_dir")
      File.rm_rf!("test_fs_copy_12345")
    end
  end

  test "fs tool copy operation fails without force when target exists" do
    File.touch!("test_fs_copy_12345")

    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "copy",
          "path" => "test_fs_copy_12345",
          "target" => "test_fs_copy_12345"
        })

      assert String.contains?(result, "already exists")
    after
      File.rm_rf!("test_fs_copy_12345")
    end
  end

  test "fs tool copy operation succeeds with force when target exists" do
    File.touch!("test_fs_copy_12345")

    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "copy",
          "path" => "test_fs_copy_12345",
          "target" => "test_fs_copy_12345",
          "force" => true
        })

      assert String.contains?(result, "Successfully copied")
    after
      File.rm_rf!("test_fs_copy_12345")
    end
  end

  test "fs tool move operation moves file" do
    File.touch!("test_fs_move_12345")

    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "move",
          "path" => "test_fs_move_12345",
          "target" => "test_fs_move_new_12345"
        })

      assert String.contains?(result, "Successfully moved")
      assert File.exists?("test_fs_move_new_12345")
      assert !File.exists?("test_fs_move_12345")
    after
      File.rm_rf!("test_fs_move_new_12345")
    end
  end

  test "fs tool remove operation removes file" do
    File.touch!("test_fs_remove_12345.txt")

    result =
      Beamcore.Agent.Tools.Fs.execute(%{
        "operation" => "remove",
        "path" => "test_fs_remove_12345.txt"
      })

    assert String.contains?(result, "Successfully removed")
    assert !File.exists?("test_fs_remove_12345.txt")
  end

  test "fs tool remove operation fails for directory without recursive" do
    File.mkdir_p!("test_fs_dir_12345")

    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{"operation" => "remove", "path" => "test_fs_dir_12345"})

      assert String.contains?(result, "Cannot remove directory")
    after
      File.rm_rf!("test_fs_dir_12345")
    end
  end

  test "fs tool remove operation succeeds for directory with recursive" do
    File.mkdir_p!("test_fs_dir_12345")
    File.touch!("test_fs_dir_12345/test_file.txt")

    result =
      Beamcore.Agent.Tools.Fs.execute(%{
        "operation" => "remove",
        "path" => "test_fs_dir_12345",
        "recursive" => true
      })

    assert String.contains?(result, "Successfully removed")
    assert !File.exists?("test_fs_dir_12345")
  end

  test "fs tool remove operation with force ignores missing path" do
    result =
      Beamcore.Agent.Tools.Fs.execute(%{
        "operation" => "remove",
        "path" => "non_existent_file_12345",
        "force" => true
      })

    assert String.contains?(result, "does not exist, but force=true")
  end

  test "fs tool mkdir operation creates directory" do
    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "mkdir",
          "path" => "test_fs_mkdir_12345"
        })

      assert String.contains?(result, "Successfully created directory")
      assert File.dir?("test_fs_mkdir_12345")
    after
      File.rm_rf!("test_fs_mkdir_12345")
    end
  end

  test "fs tool mkdir operation with nested path creates parent directories" do
    try do
      result =
        Beamcore.Agent.Tools.Fs.execute(%{
          "operation" => "mkdir",
          "path" => "test_fs_mkdir_12345/nested/path"
        })

      assert String.contains?(result, "Successfully created directory")
      assert File.dir?("test_fs_mkdir_12345/nested/path")
    after
      File.rm_rf!("test_fs_mkdir_12345")
    end
  end

  test "fs tool name returns fs" do
    assert Beamcore.Agent.Tools.Fs.name() == "fs"
  end

  test "fs tool spec contains all operations" do
    spec = Beamcore.Agent.Tools.Fs.spec()

    assert spec.function.parameters.properties.operation.enum == [
             "move",
             "copy",
             "remove",
             "touch",
             "stat",
             "exist",
             "mkdir"
           ]
  end

  test "file_type/1 handles all known file types" do
    assert Beamcore.Agent.Tools.Fs.file_type(:regular) == "regular file"
    assert Beamcore.Agent.Tools.Fs.file_type(:directory) == "directory"
    assert Beamcore.Agent.Tools.Fs.file_type(:symlink) == "symbolic link"
    assert Beamcore.Agent.Tools.Fs.file_type(:character) == "character device"
    assert Beamcore.Agent.Tools.Fs.file_type(:block) == "block device"
    assert Beamcore.Agent.Tools.Fs.file_type(:fifo) == "FIFO (named pipe)"
    assert Beamcore.Agent.Tools.Fs.file_type(:socket) == "socket"
    assert Beamcore.Agent.Tools.Fs.file_type(:unknown_type) == "unknown"
  end
end
