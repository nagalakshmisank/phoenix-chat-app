defmodule PRZMAWeb.SocialSyncControllerTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts PRZMAWeb.Router.init([])
  @did "did:example:alice"
  @auth_header {"authorization", "Bearer demo-#{@did}"}

  # PRZMAWeb.Plugs.DIDAuth is a TEST STUB — it accepts any
  # "Bearer demo-<value>" token and trusts <value> as the DID. No signature
  # verification happens. Swap this fixture out once real DID auth lands.

  test "sync_activity requires Authorization header (401 when missing)" do
    params = valid_activity_params()

    conn =
      conn(:post, "/api/v1/social/sync/activity", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 401
  end

  test "sync_activity publishes with a valid demo token" do
    params = valid_activity_params()

    conn =
      conn(:post, "/api/v1/social/sync/activity", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> put_req_header(elem(@auth_header, 0), elem(@auth_header, 1))
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert resp["id"] == params["id"]
    assert resp["status"] == "synced"
  end

  test "sync_activity returns 403 did_mismatch when body did != token did" do
    params = valid_activity_params() |> Map.put("did", "did:example:someone-else")

    conn =
      conn(:post, "/api/v1/social/sync/activity", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> put_req_header(elem(@auth_header, 0), elem(@auth_header, 1))
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"] == "did_mismatch"
  end

  test "sync_activity returns 400 when required fields are missing" do
    params = %{"id" => "act_incomplete", "did" => @did}

    conn =
      conn(:post, "/api/v1/social/sync/activity", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> put_req_header(elem(@auth_header, 0), elem(@auth_header, 1))
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 400
  end

  test "list_inbox returns activities array for authenticated did" do
    conn =
      conn(:get, "/api/v1/social/sync/inbox")
      |> put_req_header(elem(@auth_header, 0), elem(@auth_header, 1))
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 200
    resp = Jason.decode!(conn.resp_body)
    assert is_list(resp["activities"])
  end

  test "view_activity returns 404 for unknown activity_id" do
    conn =
      conn(:get, "/api/v1/social/sync/view/does-not-exist")
      |> put_req_header(elem(@auth_header, 0), elem(@auth_header, 1))
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body)["error"] == "activity_not_found"
  end

  test "save_to_vault returns 404 for unknown activity_id" do
    params = %{"activity_id" => "does-not-exist"}

    conn =
      conn(:post, "/api/v1/social/sync/save", Jason.encode!(params))
      |> put_req_header("content-type", "application/json")
      |> put_req_header(elem(@auth_header, 0), elem(@auth_header, 1))
      |> PRZMAWeb.Router.call(@opts)

    assert conn.status == 404
  end

  defp valid_activity_params do
    %{
      "id" => "act_#{System.unique_integer([:positive])}",
      "did" => @did,
      "actor" => @did,
      "activity_type" => "Create",
      "space" => "circle",
      "to" => "did:example:bob",
      "raw_json" => Jason.encode!(%{"type" => "Note"})
    }
  end
end