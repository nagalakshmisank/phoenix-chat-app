defmodule LanceRealTest do
  use ExUnit.Case, async: false

  @base "/tmp/przma_vaults_test"

  setup do
    File.rm_rf!(@base)
    :ok
  end

  test "write creates a real .lance file on disk" do
    did = "did:przma:test-user-001"
    uri = "pzdb://#{did}/calendar/core/events/evt-001"

    record = %{
      "id"    => "evt-001",
      "title" => "Team Standup",
      "start" => "2026-06-01T09:00:00Z"
    }

    {:ok, result} = PRZMA.PzDb.write(uri, record)

    assert result["record_id"] == "evt-001"
    assert result["version"]   >= 1

    # Real .lance files must exist
    lance_files = Path.wildcard("#{@base}/**/*.lance")
    assert lance_files != [], "Expected .lance files but found none"
    IO.puts("✅ Lance files created: #{inspect(lance_files)}")
  end

  test "read returns what was written" do
    did = "did:przma:read-test"
    uri = "pzdb://#{did}/vault/core/entries/entry-001"
    record = %{"id" => "entry-001", "body" => "Hello, real LanceDB!"}

    {:ok, _} = PRZMA.PzDb.write(uri, record)
    {:ok, result} = PRZMA.PzDb.read(uri)

    assert result.found == true
    assert result.record["body"] == "Hello, real LanceDB!"
  end

  test "ls shows .lance directory structure" do
    did   = "did:przma:ls-test"
    uri   = "pzdb://#{did}/chat/core/messages/msg-001"
    record = %{"id" => "msg-001", "body" => "hi"}

    {:ok, _} = PRZMA.PzDb.write(uri, record)

    IO.puts("\n📁 Lance directory tree:")
    {output, 0} = System.cmd("find", [@base, "-name", "*.lance"])
    IO.puts(output)
  end
end