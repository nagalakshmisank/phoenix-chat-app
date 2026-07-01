defmodule PRZMAWeb.FileSyncControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts PRZMAWeb.Router.init([])
  @did "did:example:alice"

  # NOTE: these tests hit PRZMA.Platform.CAS / PRZMA.PzDb directly through
  # the real router (no auth pipeline on /api/v1/files). They assume a
  # running storage backend (S3/Lance per config/test.exs). If you don't
  # have that wired up yet, stub PRZMA.Platform.CAS and PRZMA.PzDb behind
  # Mox and swap the aliases in config/test.exs first.

  test "upload_blob stores a raw body blob and returns cas_hash" do
    body = "hello world #{System.unique_integer()}"
    hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    conn =
      conn(:post, "/api/v1/files/sync/blob", body)
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-przma-did", @did)
      |> put_req_header("x-przma-blake3", hash)
      |> put_req_header("x-przma-space", "core")
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["status"] == "stored"
    assert is_binary(resp["cas_hash"])
    assert resp["size_bytes"] == byte_size(body)
  end

  test "upload_blob returns 400 when did/hash are missing" do
    conn =
      conn(:post, "/api/v1/files/sync/blob", "no headers set")
      |> put_req_header("content-type", "application/octet-stream")
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "missing fields"
  end

  test "sync_record writes file metadata and returns synced status" do
    file_id = "file_#{System.unique_integer([:positive])}"

    params = %{
      "did" => @did,
      "id" => file_id,
      "name" => "report.pdf",
      "space" => "core"
    }

    conn =
      conn(:post, "/api/v1/files/sync/record", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["file_id"] == file_id
    assert resp["status"] == "synced"
  end

  test "list_remote returns files array shape" do
    conn =
      conn(:get, "/api/v1/files/sync/list?space=core&limit=10")
      |> put_req_header("x-przma-did", @did)
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert is_list(resp["files"])
    assert resp["space"] == "core"
  end

  test "list_cas_meta returns cas_meta array shape" do
    conn =
      conn(:get, "/api/v1/files/sync/cas-meta?limit=10")
      |> put_req_header("x-przma-did", @did)
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert is_list(resp["cas_meta"])
  end

  test "download_blob returns 404 for unknown hash" do
    conn =
      conn(:get, "/api/v1/files/sync/blob/deadbeefdeadbeef?owner=#{@did}")
      |> put_req_header("x-przma-did", @did)
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "not_found"
  end

  test "list_pending returns pending_syncs array shape" do
    conn =
      conn(:get, "/api/v1/files/sync/pending?limit=10")
      |> put_req_header("x-przma-did", @did)
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert is_list(resp["pending_syncs"])
  end

  test "mark_synced acknowledges a file_id/space pair" do
    params = %{"file_id" => "file_to_mark", "space" => "core"}

    conn =
      conn(:post, "/api/v1/files/sync/mark-synced", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-przma-did", @did)
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["file_id"] == "file_to_mark"
    assert resp["status"] == "synced"
  end
end