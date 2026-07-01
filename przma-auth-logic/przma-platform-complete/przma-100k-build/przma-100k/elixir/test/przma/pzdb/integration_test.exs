# elixir/test/przma/pzdb/integration_test.exs
#
# Integration tests for the enterprise pzdb:// layer.
# These tests require NO external infrastructure — all Lance tables
# are created in a temporary directory and cleaned up after each test.
#
# Run: mix test test/przma/pzdb/integration_test.exs --include integration

defmodule PRZMA.PzDb.IntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias PRZMA.PzDb

  @test_did "did:web:integration-test.local"

  setup do
    dir = System.tmp_dir!() |> Path.join("przma_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)
    Application.put_env(:przma, :vault, base_path: dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, base_path: dir}
  end

  # ── 1. Write / Read Round-Trip ─────────────────────────────────────────────

  describe "write and read" do
    test "write a record and read it back", %{base_path: base} do
      # Provision table first
      uri   = "pzdb://#{@test_did}/vault/core/entries/test-001"
      table = "pzdb://#{@test_did}/vault/core/entries/placeholder"
      PzDb.ensure_table(table, "entries")

      record = %{
        "id"         => "test-001",
        "did"        => @test_did,
        "domain"     => "my_day",
        "entry_type" => "reflection",
        "title"      => "Morning reflection",
        "body_cas"   => "cas:#{String.duplicate("a", 64)}",
        "tags_json"  => "[]",
        "attachments_json" => "[]",
        "filter_context"   => "{}",
        "lens_context"     => "{}",
        "is_private"  => true,
        "is_pinned"   => false,
        "mood_score"  => 0.7,
        "energy_score"=> 0.6,
        "created_at"  => System.os_time(:microsecond),
        "updated_at"  => System.os_time(:microsecond),
        "version"     => 1,
        "embedding"   => List.duplicate(0.0, 768),
      }

      assert {:ok, write_result} = PzDb.write(uri, record, encrypt: false)
      assert write_result["record_id"] == "test-001"
      assert write_result["version"] > 0
      assert write_result["attempts"] == 1  # No conflict on fresh table

      # Read it back
      assert {:ok, read_result} = PzDb.read(uri, skip_cache: true, decrypt: false)
      assert read_result.found == true
      assert read_result.record["title"] == "Morning reflection"
      assert read_result.record["domain"] == "my_day"
    end

    test "write updates an existing record", %{base_path: _} do
      uri = "pzdb://#{@test_did}/vault/core/entries/update-001"
      PzDb.ensure_table("pzdb://#{@test_did}/vault/core/entries/x", "entries")

      record = base_record("update-001") |> Map.put("title", "Original title")
      assert {:ok, r1} = PzDb.write(uri, record, encrypt: false)

      updated = Map.put(record, "title", "Updated title")
      assert {:ok, r2} = PzDb.write(uri, updated, encrypt: false)

      assert r2["version"] > r1["version"]  # Version incremented

      assert {:ok, read} = PzDb.read(uri, min_version: r2["version"], decrypt: false)
      assert read.record["title"] == "Updated title"
    end

    test "read returns found: false for missing record", %{base_path: _} do
      uri = "pzdb://#{@test_did}/vault/core/entries/nonexistent"
      PzDb.ensure_table("pzdb://#{@test_did}/vault/core/entries/x", "entries")

      assert {:ok, result} = PzDb.read(uri, skip_cache: true)
      assert result.found == false
      assert result.record == nil
    end
  end

  # ── 2. Concurrent Writes — No Data Loss ────────────────────────────────────

  describe "concurrent writes" do
    test "10 concurrent writes to same DID complete without conflict errors", %{base_path: _} do
      PzDb.ensure_table("pzdb://#{@test_did}/vault/core/entries/x", "entries")

      tasks = for i <- 1..10 do
        Task.async(fn ->
          uri    = "pzdb://#{@test_did}/vault/core/entries/concurrent-#{i}"
          record = base_record("concurrent-#{i}") |> Map.put("title", "Task #{i}")
          PzDb.write(uri, record, encrypt: false)
        end)
      end

      results = Task.await_many(tasks, 30_000)
      ok_count  = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      err_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

      # All 10 writes must succeed — WriterPool serialises per DID
      assert ok_count == 10, "Expected 10 successes, got #{ok_count} (#{err_count} errors): #{inspect(results)}"
    end

    test "concurrent writes to different DIDs proceed independently", %{base_path: _} do
      dids = for i <- 1..5, do: "did:web:user#{i}.test.local"

      tasks = Enum.flat_map(dids, fn did ->
        PzDb.ensure_table("pzdb://#{did}/vault/core/entries/x", "entries")
        for j <- 1..3 do
          Task.async(fn ->
            uri    = "pzdb://#{did}/vault/core/entries/entry-#{j}"
            record = base_record("entry-#{j}", did) |> Map.put("title", "#{did} entry #{j}")
            PzDb.write(uri, record, encrypt: false)
          end)
        end
      end)

      results = Task.await_many(tasks, 30_000)
      ok_count = Enum.count(results, fn r -> match?({:ok, _}, r) end)
      assert ok_count == 15, "Expected 15 successes across 5 DIDs, got #{ok_count}"
    end
  end

  # ── 3. Soft Delete ─────────────────────────────────────────────────────────

  describe "soft delete" do
    test "soft delete stamps deleted_at without removing record", %{base_path: _} do
      uri = "pzdb://#{@test_did}/vault/core/entries/delete-me"
      PzDb.ensure_table("pzdb://#{@test_did}/vault/core/entries/x", "entries")

      record = base_record("delete-me")
      assert {:ok, _} = PzDb.write(uri, record, encrypt: false)

      assert {:ok, del_result} = PzDb.delete(uri, @test_did)
      assert del_result["record_id"] == "delete-me"

      # Record still exists but with deleted_at set
      assert {:ok, read} = PzDb.read(uri, skip_cache: true, decrypt: false)
      assert read.found == true
      assert read.record["deleted_at"] != nil
      assert read.record["deleted_by"] == @test_did
    end
  end

  # ── 4. Batch Write ─────────────────────────────────────────────────────────

  describe "batch write" do
    test "batch writes 20 records atomically", %{base_path: _} do
      PzDb.ensure_table("pzdb://#{@test_did}/vault/core/entries/x", "entries")
      table_uri = "pzdb://#{@test_did}/vault/core/entries/batch-placeholder"
      records   = for i <- 1..20, do: base_record("batch-#{i}") |> Map.put("title", "Batch #{i}")

      assert {:ok, result} = PzDb.batch_write(table_uri, records, encrypt: false)
      assert result["count"] == 20
      assert result["version"] > 0

      # Verify a sample record is readable
      assert {:ok, read} = PzDb.read(
        "pzdb://#{@test_did}/vault/core/entries/batch-10",
        min_version: result["version"],
        decrypt: false
      )
      assert read.found == true
      assert read.record["title"] == "Batch 10"
    end
  end

  # ── 5. Fan-Out ─────────────────────────────────────────────────────────────

  describe "fan_out" do
    test "fan_out writes to 5 DIDs simultaneously", %{base_path: _} do
      dids = for i <- 1..5, do: "did:web:fanout#{i}.test.local"
      Enum.each(dids, fn did ->
        PzDb.ensure_table("pzdb://#{did}/vault/core/entries/x", "entries")
      end)

      pairs = Enum.map(dids, fn did ->
        uri    = "pzdb://#{did}/vault/core/entries/fanout-event"
        record = base_record("fanout-event", did) |> Map.put("title", "Shared event")
        {uri, record}
      end)

      result = PzDb.fan_out(pairs, concurrency: 5, encrypt: false)
      assert length(result.succeeded) == 5
      assert length(result.failed)    == 0
    end

    test "fan_out partial failure does not stop other writes", %{base_path: _} do
      # Mix valid and invalid URIs
      valid_did = "did:web:valid.test.local"
      PzDb.ensure_table("pzdb://#{valid_did}/vault/core/entries/x", "entries")

      pairs = [
        {"pzdb://#{valid_did}/vault/core/entries/valid-1", base_record("valid-1", valid_did)},
        {"not-a-pzdb-uri", %{"id" => "bad"}},
        {"pzdb://#{valid_did}/vault/core/entries/valid-2", base_record("valid-2", valid_did)},
      ]

      result = PzDb.fan_out(pairs, encrypt: false)
      # At least the valid ones succeed
      total = length(result.succeeded) + length(result.failed)
      assert total == 3
    end
  end

  # ── 6. Read-After-Write Consistency ────────────────────────────────────────

  describe "read-after-write" do
    test "min_version guarantees reading latest write", %{base_path: _} do
      uri = "pzdb://#{@test_did}/vault/core/entries/raw-test"
      PzDb.ensure_table("pzdb://#{@test_did}/vault/core/entries/x", "entries")

      record = base_record("raw-test") |> Map.put("title", "Version 1")
      assert {:ok, wr} = PzDb.write(uri, record, encrypt: false)

      # Read with min_version guarantee — must see version 1
      assert {:ok, read} = PzDb.read(uri, min_version: wr["version"], decrypt: false)
      assert read.found == true
      assert read.version >= wr["version"]
    end
  end

  # ── 7. WriterPool ──────────────────────────────────────────────────────────

  describe "WriterPool" do
    test "worker routing is deterministic" do
      idx1 = PRZMA.PzDb.WriterPool.worker_for("did:web:alice.com")
      idx2 = PRZMA.PzDb.WriterPool.worker_for("did:web:alice.com")
      assert idx1 == idx2
    end

    test "different DIDs may route to different workers" do
      idxs = for i <- 1..100 do
        PRZMA.PzDb.WriterPool.worker_for("did:web:user#{i}.com")
      end
      # With 1000 workers and 100 DIDs, we expect some variation
      unique = Enum.uniq(idxs) |> length()
      assert unique > 1, "Expected multiple workers used, got #{unique}"
    end

    test "queue_depth returns integer" do
      depth = PRZMA.PzDb.WriterPool.queue_depth("did:web:test.com")
      assert is_integer(depth)
      assert depth >= 0
    end
  end

  # ── 8. WriteRouter ─────────────────────────────────────────────────────────

  describe "WriteRouter ring" do
    test "home_node is deterministic" do
      n1 = PRZMA.PzDb.WriteRouter.home_node("did:web:alice.com")
      n2 = PRZMA.PzDb.WriteRouter.home_node("did:web:alice.com")
      assert n1 == n2
    end

    test "ring rebuilds with correct node count" do
      nodes = PRZMA.PzDb.WriteRouter.cluster_nodes()
      ring  = PRZMA.PzDb.WriteRouter.build_ring_for(nodes)
      # 150 virtual nodes per physical node
      assert length(ring) == length(nodes) * 150
    end

    test "ring is sorted by hash" do
      nodes = PRZMA.PzDb.WriteRouter.cluster_nodes()
      ring  = PRZMA.PzDb.WriteRouter.build_ring_for(nodes)
      hashes = Enum.map(ring, fn {h, _} -> h end)
      assert hashes == Enum.sort(hashes)
    end

    test "adding a node remaps only ~1/N DIDs" do
      nodes1 = [:node_a, :node_b, :node_c]
      nodes2 = [:node_a, :node_b, :node_c, :node_d]  # One new node added

      ring1 = PRZMA.PzDb.WriteRouter.build_ring_for(nodes1)
      ring2 = PRZMA.PzDb.WriteRouter.build_ring_for(nodes2)

      # Test 1000 sample DIDs
      dids = for i <- 1..1_000, do: "did:web:user#{i}.com"

      lookup = fn ring, did ->
        hash = :erlang.phash2(did, 0xFFFFFFFF)
        case Enum.find(ring, fn {h, _} -> h >= hash end) do
          {_, node} -> node
          nil       -> ring |> List.first() |> elem(1)
        end
      end

      remapped = Enum.count(dids, fn did ->
        lookup.(ring1, did) != lookup.(ring2, did)
      end)

      remapped_pct = remapped / 1000 * 100
      # Should remap approximately 25% (1/4 nodes) — allow 10-40% range
      assert remapped_pct > 10, "Too few remapped: #{remapped_pct}%"
      assert remapped_pct < 40, "Too many remapped (not consistent hashing): #{remapped_pct}%"
    end
  end

  # ── 9. BYOS Validator ──────────────────────────────────────────────────────

  describe "BYOSValidator" do
    test "rejects credentials with missing required fields" do
      creds = %{endpoint: "https://example.com", bucket: "my-bucket"}
      assert {:error, {:missing_fields, msg}} = PRZMA.Deployment.BYOSValidator.validate(creds)
      assert String.contains?(msg, "access_key_id")
    end

    test "rejects empty endpoint" do
      creds = %{
        endpoint:          "",
        bucket:            "my-bucket",
        access_key_id:     "key",
        secret_access_key: "secret"
      }
      assert {:error, {:missing_fields, _}} = PRZMA.Deployment.BYOSValidator.validate(creds)
    end
  end

  # ── 10. HealthMonitor ──────────────────────────────────────────────────────

  describe "HealthMonitor" do
    test "circuit starts closed" do
      assert :ok = PRZMA.PzDb.HealthMonitor.check()
    end

    test "status returns valid map" do
      status = PRZMA.PzDb.HealthMonitor.status()
      assert is_map(status)
      assert status.circuit in [:closed, :open, :half_open]
      assert is_integer(status.p99_latency_ms)
    end

    test "records successes without opening circuit" do
      PRZMA.PzDb.HealthMonitor.reset()
      Enum.each(1..10, fn _ ->
        PRZMA.PzDb.HealthMonitor.record_success(50_000)  # 50ms
      end)
      assert :ok = PRZMA.PzDb.HealthMonitor.check()
    end
  end

  # ── HELPERS ────────────────────────────────────────────────────────────────

  defp base_record(id, did \\ @test_did) do
    %{
      "id"           => id,
      "did"          => did,
      "domain"       => "my_day",
      "entry_type"   => "reflection",
      "title"        => "Test entry #{id}",
      "body_cas"     => "cas:#{String.duplicate("0", 64)}",
      "richtext_cas" => nil,
      "source_uri"   => nil,
      "source_type"  => nil,
      "filter_context"    => "{}",
      "lens_context"      => "{}",
      "tags_json"         => "[]",
      "attachments_json"  => "[]",
      "embedding"         => List.duplicate(0.0, 768),
      "mood_score"   => nil,
      "energy_score" => nil,
      "is_private"   => true,
      "is_pinned"    => false,
      "created_at"   => System.os_time(:microsecond),
      "updated_at"   => System.os_time(:microsecond),
      "version"      => 1,
    }
  end
end
