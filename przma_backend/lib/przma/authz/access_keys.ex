defmodule Przma.Authz.AccessKeys do
  @moduledoc """
  Access keys for scripts and integrations: `X-API-Key: pk_live_…`.

    * The full key is shown ONCE, at creation. Only its SHA-256 hash and
      the first 12 characters (for the UI) are stored.
    * A key acts as its owner, but only with the scopes chosen at
      creation, and never more than the owner has right now.
    * Lifetime is capped by the owner's role (`session_policies.max_key_days`;
      0 = the role may not create keys).
    * Optional allowed_ips (CIDR list). Revoke takes effect at once on
      this node and within 60 s elsewhere.
  """

  alias Przma.Authz.{Cache, Db, Profile, Telemetry}

  @prefix "pk_live_"

  @doc """
  Creates a key for `profile`. attrs: name, scopes, days, allowed_ips.
  Returns {:ok, %{key: "pk_live_…", access_key: row}} — the only time the key is visible.
  """
  def create(%Profile{} = profile, attrs, ip \\ nil) do
    name = String.trim(attrs[:name] || "")
    scopes = Enum.uniq(attrs[:scopes] || [])
    days = attrs[:days] || 30
    max_days = profile.policy[:max_key_days] || 0
    allowed_ips = attrs[:allowed_ips] || []

    cond do
      max_days <= 0 ->
        {:error, :keys_not_allowed_for_role}

      name == "" ->
        {:error, :name_required}

      scopes == [] ->
        {:error, :scopes_required}

      days < 1 or days > max_days ->
        {:error, "days must be between 1 and #{max_days} for your role"}

      not Enum.all?(scopes, &Profile.has_scope?(profile.scopes, &1)) ->
        {:error, :scope_not_held_by_owner}

      not Enum.all?(allowed_ips, &valid_cidr?/1) ->
        {:error, :invalid_allowed_ip}

      true ->
        key = @prefix <> random()

        result =
          Db.one(
            """
            INSERT INTO przma_authz.access_keys
              (did, name, key_prefix, key_hash, scopes, allowed_ips, expires_at)
            VALUES ($1, $2, $3, $4, $5, $6::cidr[], now() + make_interval(days => $7))
            RETURNING #{columns()}
            """,
            [profile.did, name, String.slice(key, 0, 12), hash(key), scopes, cidrs(allowed_ips), days]
          )

        with {:ok, row} <- result do
          Telemetry.audit(%{
            actor: profile.did,
            action: "key.created",
            target_type: "access_key",
            target_id: row.id,
            after: %{name: name, scopes: scopes, days: days, allowed_ips: allowed_ips},
            ip: ip
          })

          {:ok, %{key: key, access_key: row}}
        end
    end
  end

  @doc "Keys of one user (never the key itself)."
  def list(did) do
    Db.all(
      "SELECT #{columns()} FROM przma_authz.access_keys WHERE did = $1 ORDER BY created_at DESC",
      [did]
    )
  end

  @doc "The owner revokes one of their keys."
  def revoke(did, id, ip \\ nil) do
    case Db.all(
           """
           UPDATE przma_authz.access_keys SET revoked_at = now()
            WHERE did = $1 AND id = $2 AND revoked_at IS NULL
           RETURNING key_hash
           """,
           [did, Db.uuid(id)]
         ) do
      {:ok, [%{key_hash: h}]} ->
        Cache.delete({:key, h})
        Telemetry.audit(%{actor: did, action: "key.revoked", target_type: "access_key", target_id: id, ip: ip})
        {:ok, true}

      {:ok, []} ->
        {:error, :not_found}

      err ->
        err
    end
  rescue
    Ecto.CastError -> {:error, :not_found}
    ArgumentError -> {:error, :not_found}
  end

  @doc "Revoked by the system (abuse rule)."
  def revoke_system(id, reason) do
    case Db.all(
           "UPDATE przma_authz.access_keys SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL RETURNING key_hash, did",
           [Db.uuid(id)]
         ) do
      {:ok, [%{key_hash: h, did: did}]} ->
        Cache.delete({:key, h})
        Telemetry.audit(%{actor: "system", action: "key.revoked", target_type: "access_key", target_id: id, after: %{reason: reason, owner: did}})
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Verifies a presented key. Returns {:ok, %{id, did, scopes}},
  {:error, :key_invalid} (unknown key, or a DB error as {:error, reason}),
  or {:error, :key_expired | :key_revoked | :key_ip_not_allowed, %{id, did}}
  so the caller can log the event against the key's owner.
  """
  def verify(key, ip) when is_binary(key) do
    h = hash(key)

    found =
      case Cache.get({:key, h}) do
        {:ok, row} ->
          {:ok, row}

        :miss ->
          case Db.one(
                 """
                 SELECT id, did, scopes, expires_at, revoked_at, last_used_at,
                        array(SELECT host(c) || '/' || masklen(c) FROM unnest(allowed_ips) AS c) AS allowed_ips
                   FROM przma_authz.access_keys WHERE key_hash = $1
                 """,
                 [h]
               ) do
            {:ok, nil} -> {:error, :key_invalid}
            {:ok, row} -> {:ok, Cache.put({:key, h}, %{row | id: Db.uuid_text(row.id)})}
            err -> err
          end
      end

    case found do
      {:ok, row} ->
        owner = %{id: row.id, did: row.did}

        cond do
          row.revoked_at != nil -> {:error, :key_revoked, owner}
          DateTime.compare(to_dt(row.expires_at), DateTime.utc_now()) != :gt -> {:error, :key_expired, owner}
          not ip_allowed?(row.allowed_ips, ip) -> {:error, :key_ip_not_allowed, owner}
          true -> touch(row, h, ip) && {:ok, %{id: row.id, did: row.did, scopes: row.scopes}}
        end

      {:error, _} = err ->
        err
    end
  end

  def verify(_key, _ip), do: {:error, :key_invalid}

  # last_used_at at most once a minute
  defp touch(row, h, ip) do
    now = DateTime.utc_now()

    stale? =
      case row.last_used_at do
        nil -> true
        t -> DateTime.diff(now, to_dt(t)) >= 60
      end

    if stale? do
      Cache.put({:key, h}, %{row | last_used_at: now})

      Db.exec(
        "UPDATE przma_authz.access_keys SET last_used_at = now(), last_used_ip = $2 WHERE key_hash = $1",
        [h, Db.inet(ip)]
      )
    end

    true
  end

  def hash(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  defp random, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  defp columns do
    "id::text AS id, name, key_prefix, scopes, " <>
      "array(SELECT host(c) || '/' || masklen(c) FROM unnest(allowed_ips) AS c) AS allowed_ips, " <>
      "expires_at, last_used_at, host(last_used_ip) AS last_used_ip, revoked_at, created_at"
  end

  defp cidrs([]), do: nil

  defp cidrs(list) do
    Enum.map(list, fn s ->
      [addr | mask] = String.split(s, "/")
      {:ok, ip} = :inet.parse_address(String.to_charlist(addr))
      bits = if tuple_size(ip) == 4, do: 32, else: 128
      %Postgrex.INET{address: ip, netmask: (mask == [] && bits) || String.to_integer(hd(mask))}
    end)
  end

  defp valid_cidr?(s) when is_binary(s) do
    [addr | mask] = String.split(s, "/")

    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} -> mask == [] or valid_mask?(mask, if(tuple_size(ip) == 4, do: 32, else: 128))
      _ -> false
    end
  end

  defp valid_cidr?(_), do: false

  defp valid_mask?([m], max) do
    case Integer.parse(m) do
      {n, ""} -> n >= 0 and n <= max
      _ -> false
    end
  end

  defp valid_mask?(_, _), do: false

  defp ip_allowed?(nil, _ip), do: true
  defp ip_allowed?([], _ip), do: true
  defp ip_allowed?(_list, nil), do: false

  defp ip_allowed?(list, ip) do
    with {:ok, addr} <- parse_ip(ip) do
      Enum.any?(list, &in_cidr?(addr, &1))
    else
      _ -> false
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: {:ok, ip}
  defp parse_ip(ip) when is_binary(ip), do: :inet.parse_address(String.to_charlist(ip))

  defp in_cidr?(addr, cidr) do
    [net | rest] = String.split(cidr, "/")

    with {:ok, net_addr} <- :inet.parse_address(String.to_charlist(net)),
         true <- tuple_size(net_addr) == tuple_size(addr) do
      bits = if tuple_size(addr) == 4, do: 32, else: 128
      mask = case rest do
        [m] -> String.to_integer(m)
        [] -> bits
      end

      prefix(addr, bits, mask) == prefix(net_addr, bits, mask)
    else
      _ -> false
    end
  end

  defp prefix(addr, bits, mask) do
    size = if bits == 32, do: 8, else: 16
    int = addr |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> acc * Bitwise.bsl(1, size) + part end)
    Bitwise.bsr(int, bits - mask)
  end

  defp to_dt(%DateTime{} = dt), do: dt
  defp to_dt(%NaiveDateTime{} = n), do: DateTime.from_naive!(n, "Etc/UTC")
end
