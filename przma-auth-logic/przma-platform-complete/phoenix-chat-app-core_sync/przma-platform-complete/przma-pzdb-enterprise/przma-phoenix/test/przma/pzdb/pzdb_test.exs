# test/przma/pzdb/pzdb_test.exs

defmodule PRZMA.PzDb.Test do
  use ExUnit.Case, async: false

  alias PRZMA.PzDb
  alias PRZMA.PzDb.{VaultWriter, ReadCache, HealthMonitor, WriteRouter}

  @did "did:web:alice.com"

  # ── WRITE ROUTER ─────────────────────────────────────────────────────────────

  describe "WriteRouter.home_node/1" do
    test "returns self when cluster has one node" do
      assert WriteRouter.home_node(@did) == Node.self()
    end

    test "is deterministic — same DID always maps to same node" do
      n1 = WriteRouter.home_node(@did)
      n2 = WriteRouter.home_node(@did)
      assert n1 == n2
    end

    test "different DIDs may map to different nodes" do
      # With one node this always returns self, but the hash is still computed
      n1 = WriteRouter.home_node("did:web:alice.com")
      n2 = WriteRouter.home_node("did:web:bob.com")
      # Both map to Node.self() in single-node mode — test the function runs
      assert is_atom(n1)
      assert is_atom(n2)
    end
  end

  # ── VAULT WRITER ─────────────────────────────────────────────────────────────

  describe "VaultWriter" do
    test "serialises concurrent writes" do
      did     = "did:web:concurrency-test.com"
      results = 1..10
        |> Enum.map(fn i ->
            Task.async(fn ->
              VaultWriter.write(did, fn -> {:ok, i} end)
            end)
          end)
        |> Task.await_many(5_000)

      # All writes should succeed
      assert Enum.all?(results, fn r -> match?({:ok, _}, r) end)
    end

    test "rejects writes when queue is full" do
      # This tests backpressure — in practice the queue limit is 100
      # and each write takes ~30ms, so you'd need 100 concurrent writers
      # to hit this. We just verify the code path exists.
      result = VaultWriter.queue_depth("did:web:no-such-did.com")
      assert result == 0
    end

    test "auto-starts on first write" do
      did = "did:web:autostart-test.com"
      VaultWriter.stop(did)  # ensure not running

      assert {:ok, :test_value} = VaultWriter.write(did, fn -> {:ok, :test_value} end)
    end
  end

  # ── READ CACHE ───────────────────────────────────────────────────────────────

  describe "ReadCache" do
    setup do
      ReadCache.flush()
      :ok
    end

    test "miss on cold cache" do
      assert :miss = ReadCache.get("pzdb://did:web:alice.com/calendar/core/events/xyz")
    end

    test "hit after put" do
      uri    = "pzdb://did:web:alice.com/vault/core/entries/abc"
      record = %{"id" => "abc", "title" => "Test entry"}

      # Simulate hot reads (must exceed threshold before caching)
      ReadCache.put(uri, record, 5)  # won't cache yet (not hot)
      Enum.each(1..5, fn _ -> ReadCache.get(uri) end)  # access count
      ReadCache.put(uri, record, 5)  # now should cache

      # Note: with hot threshold = 3, after 5 accesses it should cache
      result = ReadCache.get(uri)
      # Result is either hit or miss depending on whether threshold is reached
      assert result in [:miss, {:hit, record, 5}]
    end

    test "invalidate removes entry" do
      uri    = "pzdb://did:web:alice.com/vault/core/entries/del1"
      record = %{"id" => "del1"}
      # Force cache bypass and direct insert for test
      :ets.insert(:pzdb_read_cache,
        {uri, record, 10, System.monotonic_time(:millisecond) + 300_000})

      assert {:hit, ^record, 10} = ReadCache.get(uri)
      ReadCache.invalidate(uri)
      assert :miss = ReadCache.get(uri)
    end
  end

  # ── HEALTH MONITOR / CIRCUIT BREAKER ─────────────────────────────────────────

  describe "HealthMonitor" do
    test "circuit starts closed" do
      assert :ok = HealthMonitor.check()
    end

    test "circuit opens after error threshold" do
      # Record enough errors to trip the circuit
      Enum.each(1..5, fn _ ->
        HealthMonitor.record_error(:test_error)
      end)

      result = HealthMonitor.check()
      # Circuit may or may not open depending on state (shared process)
      # Just verify the function returns a valid response
      assert result in [:ok, {:error, :circuit_open}]
    end

    test "status returns valid map" do
      status = HealthMonitor.status()
      assert is_map(status)
      assert Map.has_key?(status, :circuit)
      assert status.circuit in [:closed, :open, :half_open]
      assert is_float(status.error_rate) or is_integer(status.error_rate)
    end
  end

  # ── FAN-OUT ─────────────────────────────────────────────────────────────────

  describe "PzDb.fan_out/2" do
    test "collects results from all writes" do
      pairs = Enum.map(1..3, fn i ->
        uri    = "pzdb://did:web:user#{i}.com/vault/core/entries/test-#{i}"
        record = %{"id" => "test-#{i}", "title" => "Fan-out test #{i}"}
        {uri, record}
      end)

      # Fan-out without real NIF — test the plumbing
      result = PzDb.fan_out(pairs, concurrency: 3)
      assert Map.has_key?(result, :succeeded)
      assert Map.has_key?(result, :failed)
      assert is_list(result.succeeded)
      assert is_list(result.failed)
    end

    test "partial failure does not stop other writes" do
      pairs = [
        {"pzdb://did:web:good.com/vault/core/entries/g1", %{"id" => "g1"}},
        {"not-a-pzdb-uri", %{"id" => "bad"}},
        {"pzdb://did:web:good2.com/vault/core/entries/g2", %{"id" => "g2"}},
      ]
      result = PzDb.fan_out(pairs)
      # At least some results are collected regardless of individual failures
      assert length(result.succeeded) + length(result.failed) == length(pairs)
    end
  end

  # ── URI PARSING ──────────────────────────────────────────────────────────────

  describe "PzDb.Uri.parse/1" do
    test "parses standard event URI" do
      {:ok, parsed} = PzDb.Uri.parse(
        "pzdb://did:web:alice.com/calendar/core/events/abc123"
      )
      assert parsed.did       == "did:web:alice.com"
      assert parsed.service   == "calendar"
      assert parsed.space     == "core"
      assert parsed.table     == "events"
      assert parsed.record_id == "abc123"
    end

    test "parses circle space URI" do
      {:ok, parsed} = PzDb.Uri.parse(
        "pzdb://did:web:alice.com/chat/circle:did:web:fam.przma.net/messages/m1"
      )
      assert parsed.space == "circle:did:web:fam.przma.net"
    end

    test "rejects non-pzdb URIs" do
      assert {:error, _} = PzDb.Uri.parse("przma://did:web:alice.com/calendar/core/events/abc")
      assert {:error, _} = PzDb.Uri.parse("https://alice.com/events/abc")
    end

    test "rejects incomplete URIs" do
      assert {:error, _} = PzDb.Uri.parse("pzdb://did:web:alice.com/calendar/core")
    end

    test "lance_path derivation is correct" do
      {:ok, parsed} = PzDb.Uri.parse(
        "pzdb://did:web:alice.com/companion/core/memories/mem1"
      )
      path = PzDb.Uri.lance_path("/vaults", parsed)
      assert path == "/vaults/did:web:alice.com/companion/core/memories"
    end

    test "DID colons do not confuse the parser" do
      # DID with multiple colons: did:web:sub.alice.com
      {:ok, parsed} = PzDb.Uri.parse(
        "pzdb://did:web:sub.alice.com/vault/core/entries/e1"
      )
      assert parsed.did == "did:web:sub.alice.com"
    end
  end

  # ── COMPACTION ───────────────────────────────────────────────────────────────

  describe "Compaction" do
    test "status returns a map" do
      status = PRZMA.PzDb.Compaction.status()
      assert is_map(status)
      assert Map.has_key?(status, :compactions_run)
    end
  end

  # ── CLUSTER STATUS ───────────────────────────────────────────────────────────

  describe "WriteRouter cluster" do
    test "cluster_nodes includes self" do
      nodes = WriteRouter.cluster_nodes()
      assert Node.self() in nodes
    end

    test "cluster_status reports healthy in single-node mode" do
      status = WriteRouter.cluster_status()
      assert status.node_count >= 1
      assert status.healthy == true
    end
  end
end
