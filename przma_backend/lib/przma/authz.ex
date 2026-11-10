defmodule Przma.Authz do
  @moduledoc """
  Authorisation scope — one entry point for every API call.

  authorize/1 is called by the GraphQL middleware
  (PRZMAWeb.Graphql.Middleware.Authz) and the REST plug
  (PRZMAWeb.Plugs.Authorize) with:

      %{did, kind: "graphql_query" | "graphql_mutation" | "rest", endpoint: "createEvent",
        method: :jwt | :api_key, key: %{id, scopes} | nil,
        sid, claims, ip, user_agent}

  Checks, in order (first failure wins):

    1. endpoint registered and active        endpoint_not_registered / endpoint_disabled
    2. account exists                        account_not_registered
    3. account active                        account_suspended
    4. storage not being migrated            storage_migrating
    5. session valid (JWT only)              session_expired / session_revoked
    6. role has the endpoint's scope         scope_denied
       (+ the access key has it)
    7. plan / workspace has the feature      feature_not_in_plan
    8. rate limit                            rate_limited

  Allowed calls are counted in usage_daily; refused calls are counted
  as errors and written to security_events.

  Mode (config :przma, :authz, mode: …, env AUTHZ_MODE):
    "enforce" — refuse failed calls (default)
    "log"     — allow everything, but log what WOULD be refused
                (use this for the first days after deploying)
    "off"     — skip all checks
  """

  require Logger
  alias Przma.Authz.{AccessKeys, Endpoints, Profile, Sessions, Telemetry}

  @http_status %{
    endpoint_not_registered: 403,
    endpoint_disabled: 403,
    account_not_registered: 403,
    account_suspended: 403,
    storage_migrating: 503,
    session_expired: 401,
    session_revoked: 401,
    scope_denied: 403,
    feature_not_in_plan: 403,
    rate_limited: 429,
    quota_exceeded: 413,
    key_invalid: 401,
    key_expired: 401,
    key_revoked: 401,
    key_ip_not_allowed: 403,
    authz_unavailable: 503
  }

  @hints %{
    account_not_registered: "Call completeRegistration first.",
    scope_denied: "Your role does not include this API. Upgrade your plan or ask an admin.",
    feature_not_in_plan: "This feature is not in your plan.",
    session_expired: "Log in again.",
    session_revoked: "This session was ended. Log in again.",
    rate_limited: "Too many calls this minute. Try again shortly.",
    storage_migrating: "Your storage is being moved. Try again in a few minutes.",
    account_suspended: "Your account is suspended. Contact support."
  }

  def mode, do: Keyword.get(Application.get_env(:przma, :authz, []), :mode, "enforce")

  def http_status(code), do: Map.get(@http_status, code, 403)
  def hint(code), do: Map.get(@hints, code)

  @doc "Cached access profile of a user (nil = not registered)."
  defdelegate profile(did), to: Profile, as: :get

  @doc ":ok or {:error, code, details}."
  @spec authorize(map()) :: :ok | {:error, atom(), map()}
  def authorize(req) do
    case mode() do
      "off" ->
        :ok

      mode ->
        result = decide(req)
        record(req, result)

        case {mode, result} do
          {"log", {:error, code, _}} ->
            Logger.warning("Authz (log mode) would refuse #{req.endpoint} for #{req[:did]}: #{code}")
            :ok

          {_, result} ->
            result
        end
    end
  end

  # ── decision ──────────────────────────────────────────────────────────

  defp decide(req) do
    with {:ok, ep} <- endpoint(req), do: check(ep, req)
  end

  defp endpoint(req) do
    case Endpoints.lookup(req.kind, req.endpoint) do
      {:ok, %{active: false} = ep} -> fail(:endpoint_disabled, ep)
      {:ok, ep} -> {:ok, ep}
      {:error, :endpoint_not_registered} -> fail(:endpoint_not_registered, nil)
      {:error, reason} -> unavailable(reason)
    end
  end

  # completeRegistration only needs a valid Keycloak token (JWT, never a key):
  # the account is created by that call.
  defp check(%{scope: "auth:register"} = ep, %{method: :jwt} = req), do: rate(ep, req_who(req), ep)
  defp check(%{scope: "auth:register"} = ep, _req), do: fail(:scope_denied, ep)

  defp check(ep, req) do
    with {:ok, profile} <- load_profile(req, ep),
         :ok <- account_active(profile, ep),
         :ok <- storage_ready(profile, ep),
         :ok <- session(profile, req, ep),
         :ok <- scope(profile, req, ep),
         :ok <- feature(profile, ep),
         :ok <- rate(ep, req_who(req), ep) do
      :ok
    end
  end

  defp load_profile(req, ep) do
    case Profile.get(req.did) do
      {:ok, nil} -> fail(:account_not_registered, ep)
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> unavailable(reason)
    end
  end

  defp account_active(%{status: s}, _ep) when s in ["active", "pending_setup"], do: :ok
  defp account_active(_profile, ep), do: fail(:account_suspended, ep)

  defp storage_ready(%{storage: %{status: "migrating"}}, ep), do: fail(:storage_migrating, ep)
  defp storage_ready(_profile, _ep), do: :ok

  defp session(profile, %{method: :jwt} = req, ep) do
    case Sessions.check(profile, req) do
      :ok -> :ok
      {:error, code} when code in [:session_expired, :session_revoked] -> fail(code, ep)
      {:error, reason} -> unavailable(reason)
    end
  end

  defp session(_profile, _req, _ep), do: :ok

  defp scope(profile, req, ep) do
    cond do
      not Profile.has_scope?(profile.scopes, ep.scope) ->
        fail(:scope_denied, ep, %{needed: ep.scope, role: profile.roles})

      req.method == :api_key and not Profile.has_scope?(req.key.scopes, ep.scope) ->
        fail(:scope_denied, ep, %{needed: ep.scope, key_scopes: req.key.scopes})

      true ->
        :ok
    end
  end

  defp feature(_profile, %{feature: nil}), do: :ok

  defp feature(profile, ep) do
    if MapSet.member?(profile.features, ep.feature),
      do: :ok,
      else: fail(:feature_not_in_plan, ep, %{needed: ep.feature, plan: profile.plan})
  end

  defp rate(_ep, who, ep) do
    case Telemetry.rate_limit(who, ep.name, ep.rate_limit) do
      :ok -> :ok
      {:error, :rate_limited} -> fail(:rate_limited, ep, %{limit_per_min: ep.rate_limit})
    end
  end

  defp req_who(%{method: :api_key, key: %{id: id}}), do: {:key, id}
  defp req_who(%{did: did}), do: did

  defp fail(code, ep, extra \\ %{}) do
    {:error, code, Map.merge(%{endpoint: ep && ep.name, scope: ep && ep.scope}, extra)}
  end

  defp unavailable(reason) do
    Logger.error("Authz unavailable: #{inspect(reason)}")
    {:error, :authz_unavailable, %{}}
  end

  # ── telemetry for every decision ──────────────────────────────────────

  defp record(req, :ok) do
    service =
      case Endpoints.lookup(req.kind, req.endpoint) do
        {:ok, ep} -> Profile.service_of(ep.scope)
        _ -> "other"
      end

    Telemetry.count(req[:did], service)
  end

  defp record(_req, {:error, :authz_unavailable, _}), do: :ok

  defp record(req, {:error, code, details}) do
    Telemetry.count(req[:did], Profile.service_of(details[:scope]), true)
    key_id = req[:key] && req.key[:id]

    action =
      case Telemetry.key_denied(key_id, req[:did], req[:ip]) do
        :revoked -> "key_revoked"
        :ok -> if(mode() == "log", do: "logged_only", else: "refused")
      end

    Telemetry.security_event(%{
      did: req[:did],
      key_id: key_id,
      type: code,
      ip: req[:ip],
      details: Map.merge(details, %{method: to_string(req[:method]), kind: req.kind, api: req.endpoint}),
      action: action
    })
  end

  # ── access keys (used by KeycloakAuth) ────────────────────────────────

  @doc "Resolves an X-API-Key header to its owner. Logs refused keys."
  def verify_access_key(key, ip) do
    case AccessKeys.verify(key, ip) do
      {:ok, k} ->
        {:ok, k}

      {:error, code, owner} ->
        Telemetry.security_event(%{did: owner.did, key_id: owner.id, type: code, ip: ip, action: "refused"})
        Telemetry.key_denied(owner.id, owner.did, ip)
        {:error, code}

      {:error, :key_invalid} ->
        Telemetry.security_event(%{type: :key_invalid, ip: ip, details: %{key_prefix: String.slice(key, 0, 12)}, action: "refused"})
        {:error, :key_invalid}

      {:error, reason} ->
        Logger.error("Authz: access key check failed: #{inspect(reason)}")
        {:error, :authz_unavailable}
    end
  end

  # ── storage quota (used by Przma.Vault.Cas / Files) ───────────────────

  @doc ":ok or {:error, :quota_exceeded} before writing `bytes` more for `did`."
  def check_quota(did, bytes) do
    if mode() == "off" do
      :ok
    else
      case Przma.Authz.Db.one("SELECT quota_bytes, used_bytes FROM przma_authz.storage_usage WHERE did = $1", [did]) do
        {:ok, %{quota_bytes: q, used_bytes: u}} when u + bytes > q ->
          Telemetry.security_event(%{did: did, type: :quota_exceeded, details: %{quota_bytes: q, used_bytes: u, upload_bytes: bytes}, action: if(mode() == "log", do: "logged_only", else: "refused")})
          if mode() == "log", do: :ok, else: {:error, :quota_exceeded}

        _ ->
          # no row (unregistered / system DID) or DB down: do not block uploads
          :ok
      end
    end
  end

  @doc "Adds stored bytes (new unique content) to storage_usage and usage_daily."
  def add_storage(did, bytes, files \\ 1) when is_binary(did) and is_integer(bytes) do
    Przma.Authz.Db.exec(
      """
      UPDATE przma_authz.storage_usage
         SET used_bytes = used_bytes + $2, file_count = file_count + $3, updated_at = now()
       WHERE did = $1
      """,
      [did, bytes, files]
    )

    Telemetry.bytes(did, "files", bytes)
    Przma.Authz.Cache.delete({:profile, did})
    :ok
  end
end
