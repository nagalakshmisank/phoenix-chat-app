# lib/przma/platform/namespace.ex
#
# Canonical PRZMA namespace for the Elixir backend.
#
# This is the single source of truth for the on-disk / on-S3 layout. It mirrors
# the Rust `przma_platform::namespace` module and the local desktop vault
# (`store.rs` -> resolve_db_path), so the backend S3 tree is structurally
# identical to a user's local vault.
#
# URI grammar (physical):  pzdb://{did}/{service}/{space}/{res_type}/{id}
#
# Three spaces per user:
#   "core"          -> personal, owner-only        (the space we sync first)
#   "commons"       -> public
#   "circle:{cid}"  -> shared with a circle (cid = circle DID)
#
# Physical mirror layout (matches local store.rs):
#   {root}/{sanitized_did}/files/core/files.lance/
#   {root}/{sanitized_did}/files/commons/files.lance/
#   {root}/{sanitized_did}/files/circles/{cid}/files.lance/
#   {root}/{sanitized_did}/cas/{shard}/{hash}
#
# When {root} is an s3:// URI (Linode), LanceDB + CAS write straight to S3.

defmodule PRZMA.Platform.Namespace do
  @valid_services ~w(vault calendar chat files metadata ai agents creative companion)

  @doc "The three spaces every user has on the backend."
  def spaces, do: ["core", "commons", "circle"]

  @doc """
  Resolve a `pzdb://` URI into `{connection_dir, table_name}`.

  Connecting LanceDB at `connection_dir` and opening the simple `table_name`
  yields `{connection_dir}/{table_name}.lance/` -- i.e. the same shape the local
  `FileStore` produces with `connect(space_dir)` + `open_table("files")`.

  Example:
    resolve("s3://perkeep/lancedb",
            "pzdb://did:web:alice.com/files/core/file/abc")
    => {"s3://perkeep/lancedb/did_web_alice.com/files/core", "files"}
  """
  def resolve(root, "pzdb://" <> rest) do
    case String.split(rest, "/") do
      [did, service, space, res_type | _] ->
        dir =
          join_uri([
            root,
            sanitize_did(did),
            validate_service!(service),
            space_path(space)
          ])

        {dir, table_for(res_type)}

      _ ->
        raise ArgumentError, "malformed pzdb uri: pzdb://#{rest}"
    end
  end

  @doc "Connection dir for a user's `files` tables in a given space."
  def files_dir(root, did, space) do
    join_uri([root, sanitize_did(did), "files", space_path(space)])
  end

  @doc "CAS root for a user (mirrors local {root}/{did}/cas)."
  def cas_dir(root, did) do
    join_uri([root, sanitize_did(did), "cas"])
  end

  # ── space -> physical path segment (mirror of Rust resolve_db_path) ──────────
  def space_path("core"), do: "core"
  def space_path("commons"), do: "commons"
  # Local stores circles as `circles/{circle_did}`; keep it identical to mirror.
  def space_path("circle:" <> cid), do: "circles/" <> cid
  def space_path(other),
    do: raise(ArgumentError, "unknown space (expected core|commons|circle:<did>): #{inspect(other)}")

  @doc "DID colons -> underscores (S3-key / Windows safe), as in local store.rs."
  def sanitize_did(did), do: String.replace(did, ":", "_")

  # res_type ("file") -> lance table ("files"), matching Rust res_type_to_table.
  defp table_for(res_type), do: res_type <> "s"

  defp validate_service!(s) when s in @valid_services, do: s
  defp validate_service!(s), do: raise(ArgumentError, "unknown service: #{s}")

  # Plain "/" join -- do NOT use Path.join, it collapses the "s3://" double slash.
  defp join_uri(parts), do: Enum.join(parts, "/")
end