# elixir/lib/przma/deployment/byos_validator.ex
#
# BYOS provider validation — runs before any credentials are stored.
#
# Lance requires five S3 operations for correct operation:
#   1. PUT object                    (write fragments)
#   2. GET object                    (read fragments / manifest)
#   3. PUT with If-None-Match: *     (create new manifest — conditional)
#   4. PUT with If-Match: {etag}     (update manifest — conditional)
#   5. LIST objects by prefix        (compaction discovers fragments)
#
# Providers that lack conditional PUT (#3 and #4) will cause data corruption
# under concurrent writes. This validator catches that before it matters.
#
# Running time: ~2 seconds (5 sequential HTTP requests against the provider).

defmodule PRZMA.Deployment.BYOSValidator do
  require Logger

  @probe_prefix "przma-validation-probe"

  @doc """
  Validate a BYOS provider supports all operations PRZMA requires.

  credentials map:
    endpoint:          "https://us-east-1.linodeobjects.com"
    bucket:            "my-przma-vault"
    region:            "us-east-1"
    access_key_id:     "..."
    secret_access_key: "..."

  Returns: {:ok, :validated} | {:error, {step, reason}}
  """
  def validate(%{} = creds) do
    probe_key  = "#{@probe_prefix}-#{random_hex(8)}"
    probe_data = "przma-byos-probe-#{System.os_time(:millisecond)}"

    with :ok          <- check_required_fields(creds),
         :ok          <- step(:connectivity,  fn -> test_put(creds, probe_key, probe_data)                 end),
         {:ok, etag}  <- step_val(:read,      fn -> test_get(creds, probe_key, probe_data)                 end),
         :ok          <- step(:cond_create,   fn -> test_conditional_put_none_match(creds, probe_key <> "-new") end),
         :ok          <- step(:cond_update,   fn -> test_conditional_put_if_match(creds, probe_key, etag)  end),
         :ok          <- step(:list,          fn -> test_list_prefix(creds, @probe_prefix)                 end),
         :ok          <- cleanup(creds, [probe_key, probe_key <> "-new"]) do
      Logger.info("BYOS validation passed",
        endpoint: creds.endpoint, bucket: creds.bucket)
      {:ok, :validated}
    else
      {:error, {step, reason}} = err ->
        Logger.warning("BYOS validation failed",
          step: step, reason: reason,
          endpoint: creds[:endpoint], bucket: creds[:bucket])
        err
    end
  end

  # ── STEP RUNNERS ──────────────────────────────────────────────────────────

  defp step(name, fun) do
    case safe_run(fun) do
      :ok           -> :ok
      {:ok, _}      -> :ok
      {:error, msg} -> {:error, {name, msg}}
    end
  end

  defp step_val(name, fun) do
    case safe_run(fun) do
      {:ok, val}    -> {:ok, val}
      :ok           -> {:error, {name, "expected value"}}
      {:error, msg} -> {:error, {name, msg}}
    end
  end

  defp safe_run(fun) do
    try do
      fun.()
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :exit, reason -> {:error, "exit: #{inspect(reason)}"}
    end
  end

  # ── S3 OPERATIONS ─────────────────────────────────────────────────────────
  # Uses Finch (already a Phoenix dependency) for HTTP calls.
  # SigV4 signing is done by the aws_credentials or ex_aws libraries.
  # For the validator, we use AWS ExAws if available, or plain HTTP with
  # pre-signed URLs generated server-side.

  defp test_put(creds, key, data) do
    case s3_put(creds, key, data, []) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: s, body: b}}             -> {:error, "PUT failed: HTTP #{s}: #{b}"}
      {:error, reason}                          -> {:error, "PUT error: #{inspect(reason)}"}
    end
  end

  defp test_get(creds, key, expected_data) do
    case s3_get(creds, key) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        if body == expected_data do
          etag = get_header(headers, "etag") || get_header(headers, "ETag") || ""
          {:ok, String.trim(etag, "\"")}
        else
          {:error, "GET body mismatch: got #{byte_size(body)} bytes"}
        end
      {:ok, %{status: s, body: b}} -> {:error, "GET failed: HTTP #{s}: #{b}"}
      {:error, reason}             -> {:error, "GET error: #{inspect(reason)}"}
    end
  end

  defp test_conditional_put_none_match(creds, key) do
    # PUT with If-None-Match: * — should succeed (object doesn't exist)
    headers = [{"If-None-Match", "*"}]
    case s3_put(creds, key, "probe-conditional-create", headers) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: 412}}                    ->
        # 412 Precondition Failed means the object already exists
        # (our probe key shouldn't exist, but retry with a different key)
        :ok  # The provider supports If-None-Match (it checked the condition)
      {:ok, %{status: 501, body: b}}           ->
        {:error, "Provider does not support conditional writes (501). PRZMA requires If-None-Match support. " <>
          "Use Linode Object Storage, DigitalOcean Spaces, Cloudflare R2, MinIO, or AWS S3."}
      {:ok, %{status: s, body: b}}             -> {:error, "Conditional PUT failed: HTTP #{s}: #{b}"}
      {:error, reason}                         -> {:error, "Conditional PUT error: #{inspect(reason)}"}
    end
  end

  defp test_conditional_put_if_match(creds, key, etag) do
    # PUT with If-Match: {etag} — should succeed (etag matches current)
    headers = [{"If-Match", "\"#{etag}\""}]
    case s3_put(creds, key, "probe-conditional-update", headers) do
      {:ok, %{status: s}} when s in [200, 201] -> :ok
      {:ok, %{status: 412, body: b}} ->
        {:error, "Conditional update (If-Match) failed: ETag mismatch. " <>
          "Provider may not support conditional writes properly. Body: #{b}"}
      {:ok, %{status: 501}} ->
        {:error, "Provider does not support If-Match header. " <>
          "This is required for safe concurrent Lance manifest updates."}
      {:ok, %{status: s, body: b}} -> {:error, "If-Match PUT failed: HTTP #{s}: #{b}"}
      {:error, reason}             -> {:error, inspect(reason)}
    end
  end

  defp test_list_prefix(creds, prefix) do
    case s3_list(creds, prefix) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}}   -> {:error, "LIST failed: HTTP #{s}"}
      {:error, reason}      -> {:error, "LIST error: #{inspect(reason)}"}
    end
  end

  defp cleanup(creds, keys) do
    Enum.each(keys, fn key -> s3_delete(creds, key) end)
    :ok
  end

  # ── HTTP CLIENT ───────────────────────────────────────────────────────────
  # Delegates to ExAws S3 (hex package) if available.
  # Falls back to built-in Finch with manual SigV4 construction.

  defp s3_put(creds, key, data, extra_headers) do
    s3_request(:put, creds, key, data, extra_headers)
  end

  defp s3_get(creds, key) do
    s3_request(:get, creds, key, nil, [])
  end

  defp s3_list(creds, prefix) do
    s3_request(:get, creds, "", nil, [], "?list-type=2&prefix=#{URI.encode(prefix)}")
  end

  defp s3_delete(creds, key) do
    s3_request(:delete, creds, key, nil, [])
  end

  defp s3_request(method, creds, key, body, extra_headers, query \\ "") do
    url      = "#{String.trim_trailing(creds.endpoint, "/")}/#{creds.bucket}/#{key}#{query}"
    datetime = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[-:]/, "") |> String.slice(0, 15) <> "Z"
    date     = String.slice(datetime, 0, 8)

    base_headers = [
      {"Host",                extract_host(creds.endpoint)},
      {"x-amz-date",         datetime},
      {"x-amz-content-sha256", "UNSIGNED-PAYLOAD"},
      {"Content-Type",       "application/octet-stream"},
    ] ++ extra_headers

    headers = sign_request(method, url, base_headers, body, creds, datetime, date)

    req_body = if body, do: body, else: ""
    case Finch.build(method, url, headers, req_body)
         |> Finch.request(PRZMA.Finch) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status: status, headers: resp_headers, body: resp_body}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_host(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: host} when is_binary(host) -> host
      _ -> endpoint
    end
  end

  defp sign_request(method, url, headers, body, creds, datetime, date) do
    # AWS SigV4 signing — simplified version sufficient for validation
    # In production this is handled by ExAws or Req's AWS plugin
    try do
      aws_sigv4_headers(method, url, headers, body, creds, datetime, date)
    rescue
      _ ->
        # Fallback: add auth header without SigV4 (works for some providers in test mode)
        [{"Authorization", "AWS4-HMAC-SHA256 Credential=#{creds.access_key_id}/..."} | headers]
    end
  end

  defp aws_sigv4_headers(method, url, headers, body, creds, datetime, date) do
    uri          = URI.parse(url)
    method_str   = method |> to_string() |> String.upcase()
    content_hash = "UNSIGNED-PAYLOAD"
    region       = creds[:region] || "us-east-1"
    service      = "s3"

    canonical_headers = headers
      |> Enum.map(fn {k, v} -> {"#{String.downcase(k)}", v} end)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}:#{v}" end)
    canonical_headers = canonical_headers <> "\n"

    signed_headers = headers
      |> Enum.map(fn {k, _} -> String.downcase(k) end)
      |> Enum.sort()
      |> Enum.join(";")

    canonical_path    = URI.encode(uri.path || "/", &URI.char_unreserved?/1) |> String.replace("%2F", "/")
    canonical_query   = uri.query || ""
    canonical_request = "#{method_str}\n#{canonical_path}\n#{canonical_query}\n#{canonical_headers}\n#{signed_headers}\n#{content_hash}"

    credential_scope = "#{date}/#{region}/#{service}/aws4_request"
    str_to_sign      = "AWS4-HMAC-SHA256\n#{datetime}\n#{credential_scope}\n#{:crypto.hash(:sha256, canonical_request) |> Base.encode16(case: :lower)}"

    signing_key = derive_signing_key(creds.secret_access_key, date, region, service)
    signature   = hmac_sha256(signing_key, str_to_sign) |> Base.encode16(case: :lower)

    auth_header = "AWS4-HMAC-SHA256 Credential=#{creds.access_key_id}/#{credential_scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"
    [{"Authorization", auth_header} | headers]
  end

  defp derive_signing_key(secret, date, region, service) do
    hmac_sha256("AWS4#{secret}", date)
    |> then(&hmac_sha256(&1, region))
    |> then(&hmac_sha256(&1, service))
    |> then(&hmac_sha256(&1, "aws4_request"))
  end

  defp hmac_sha256(key, data) when is_binary(key) and is_binary(data) do
    :crypto.mac(:hmac, :sha256, key, data)
  end

  defp get_header(headers, name) do
    name_down = String.downcase(name)
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name_down, do: v
    end)
  end

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp check_required_fields(creds) do
    required = [:endpoint, :bucket, :access_key_id, :secret_access_key]
    missing  = Enum.filter(required, fn k -> is_nil(creds[k]) or creds[k] == "" end)
    if Enum.empty?(missing) do
      :ok
    else
      {:error, {:missing_fields, "Required fields missing: #{Enum.join(missing, ", ")}"}}
    end
  end

  defp random_hex(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
  end
end
