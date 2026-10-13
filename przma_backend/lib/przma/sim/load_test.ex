defmodule Przma.Sim.LoadTest do
  @moduledoc """
  Simulation / load test of the whole LanceDB-backed backend.

  Runs INSIDE the app (iex) and calls the same service functions the
  GraphQL resolvers call, so every request still goes through the pzdb
  URI, NamespacePolicy, PzdbAuthorization, DocWriter, the Lance NIF and
  S3. Only Keycloak and HTTP are skipped (sim users get a generated
  identity), so the numbers are for the storage + service layer.

  WHAT IT DOES (in this order, each phase timed):
    1. users        register N users (profile + _meta + directory account)
    2. social       follows (+ follow notifications) and contacts
    3. files        uploads with a size mix, some public (Postgres copy),
                    some duplicates (CAS dedup / ref_count)
    4. dm           direct messages between random pairs, part of them
                    with an attachment (upload + send)
    5. fanin        everybody messages user 1 at the same moment (hot user)
    6. circles      create circles, members join by invite code
                    (join notifications), circle messages (fan-out)
    7. reads        chat list, unread badge, conversations, notifications,
                    files, circles, profile, attachment URL, save-to-vault
    8. checks       counts: outbox = inbox, unread counters, circle copies,
                    follow notifications, dedup ref_count
    9. compaction   read speed of the hottest inbox before / after compaction
   10. storage      S3 objects and bytes: Lance (by folder) vs CAS blobs

  USAGE (server, test bucket, free port — see GUIDE):
      PORT=4300 iex -S mix
      iex> Przma.Sim.LoadTest.run(profile: :smoke)          # 1-2 minutes
      iex> Przma.Sim.LoadTest.run(profile: :medium)
      iex> Przma.Sim.LoadTest.run(profile: :heavy)
      iex> Przma.Sim.LoadTest.run(profile: :medium, users: 80, concurrency: 24)
      iex> Przma.Sim.LoadTest.estimate(profile: :heavy)     # size of the run, no writes

  Every run gets its own run id; all its users are did:przma:sim<runid>_NNNN,
  so data of different runs never mixes. Remove one run's data with:
      iex> Przma.Sim.LoadTest.cleanup("<runid>")                  # dry run: shows what would go
      iex> Przma.Sim.LoadTest.cleanup("<runid>", confirm: true)   # deletes ONLY that run's data

  The report is printed and saved as JSON (default /tmp/przma_sim_<runid>.json).
  """

  require Logger

  alias Przma.Chat.{Messages, Threads}
  alias Przma.Circle.{Circles, Members}
  alias Przma.Circle.Messages, as: CircleMessages
  alias Przma.Notify.Notifications
  alias Przma.Sim.Metrics
  alias Przma.Social.{Contacts, Follows, Key}
  alias Przma.Storage.{LanceCompactor, LanceDocPath}
  alias Przma.Vault.{Files, Profile, PzdbConnector, PzdbUri, Registration}

  @kb 1024
  @mb 1024 * 1024

  # file_sizes / attachment_sizes: [{bytes, weight}] — weight = share of uploads
  @profiles %{
    smoke: [
      users: 6, follows_per_user: 2, contacts_per_user: 2,
      files_per_user: 2, file_sizes: [{20 * @kb, 70}, {512 * @kb, 30}],
      public_ratio: 0.25, dup_users: 2,
      dm_peers_per_user: 2, dms_per_peer: 5, attachment_ratio: 0.2,
      attachment_sizes: [{50 * @kb, 80}, {1 * @mb, 20}],
      fanin: true,
      circles: 1, circle_size: 5, circle_msgs_per_member: 3,
      read_rounds: 2, save_to_vault: 2, check_pairs: 20,
      compaction_reads: 10, concurrency: 4
    ],
    medium: [
      users: 50, follows_per_user: 5, contacts_per_user: 5,
      files_per_user: 5, file_sizes: [{50 * @kb, 50}, {1 * @mb, 35}, {5 * @mb, 15}],
      public_ratio: 0.1, dup_users: 5,
      dm_peers_per_user: 5, dms_per_peer: 20, attachment_ratio: 0.1,
      attachment_sizes: [{100 * @kb, 70}, {2 * @mb, 30}],
      fanin: true,
      circles: 5, circle_size: 20, circle_msgs_per_member: 5,
      read_rounds: 3, save_to_vault: 10, check_pairs: 100,
      compaction_reads: 30, concurrency: 16
    ],
    heavy: [
      users: 200, follows_per_user: 10, contacts_per_user: 10,
      files_per_user: 10, file_sizes: [{100 * @kb, 40}, {2 * @mb, 40}, {8 * @mb, 15}, {20 * @mb, 5}],
      public_ratio: 0.1, dup_users: 20,
      dm_peers_per_user: 10, dms_per_peer: 50, attachment_ratio: 0.1,
      attachment_sizes: [{200 * @kb, 70}, {5 * @mb, 30}],
      fanin: true,
      circles: 10, circle_size: 100, circle_msgs_per_member: 10,
      read_rounds: 3, save_to_vault: 30, check_pairs: 200,
      compaction_reads: 50, concurrency: 32
    ]
  }

  # ── public API ───────────────────────────────────────────────────────

  @doc "Expected volume of a run (no writes)."
  def estimate(opts \\ []) do
    o = options(opts)
    n = o[:users]
    files = n * o[:files_per_user]
    dms = n * o[:dm_peers_per_user] * o[:dms_per_peer]
    att = round(dms * o[:attachment_ratio])
    circle_msgs = o[:circles] * o[:circle_size] * o[:circle_msgs_per_member]

    bytes =
      files * avg_size(o[:file_sizes]) + o[:dup_users] * avg_size(o[:file_sizes]) +
        att * avg_size(o[:attachment_sizes])

    est = %{
      users: n,
      file_uploads: files + o[:dup_users],
      direct_messages: dms + if(o[:fanin], do: n - 1, else: 0),
      attachments: att,
      circle_messages: circle_msgs,
      circle_inbox_copies: circle_msgs * (o[:circle_size] - 1),
      approx_blob_gb: Float.round(bytes / (1024 * 1024 * 1024), 2),
      approx_lance_commits: n * 4 + files * 2 + dms * 4 + circle_msgs * o[:circle_size] * 2
    }

    IO.puts("\nEstimate (#{o[:profile]}):")
    Enum.each(est, fn {k, v} -> IO.puts("  #{String.pad_trailing(to_string(k), 22)} #{v}") end)
    est
  end

  @doc "Runs the whole simulation. Returns the report map."
  def run(opts \\ []) do
    o = options(opts)
    run_id = Keyword.get(opts, :run_id) || random_id()
    :rand.seed(:exsss, {String.length(run_id), 7, 42})
    Metrics.reset()

    users = for i <- 1..o[:users], do: user(run_id, i)
    IO.puts("\n=== PRZMA LanceDB simulation  run=#{run_id}  profile=#{o[:profile]}  base=#{base()} ===")
    estimate(opts)

    sampler = Metrics.start_sampler(Enum.map(users, & &1.did))
    started = now_ms()
    ctx = %{o: o, run_id: run_id, users: users, phases: [], checks: [], state: new_state()}

    ctx =
      ctx
      |> phase(:users, &phase_users/1)
      |> phase(:social, &phase_social/1)
      |> phase(:files, &phase_files/1)
      |> phase(:dm, &phase_dm/1)
      |> phase(:fanin, &phase_fanin/1)
      |> phase(:circles, &phase_circles/1)
      |> phase(:reads, &phase_reads/1)
      |> phase(:checks, &phase_checks/1)
      |> phase(:compaction, &phase_compaction/1)
      |> phase(:storage, &phase_storage/1)

    Metrics.stop_sampler(sampler)
    report = build_report(ctx, now_ms() - started)
    print_report(report)
    save_report(report, Keyword.get(opts, :report_dir, "/tmp"))
    report
  end

  # ── phases ───────────────────────────────────────────────────────────

  defp phase(ctx, name, fun) do
    IO.puts("\n▶ #{name} ...")
    t0 = now_ms()
    ctx = fun.(ctx)
    ms = now_ms() - t0
    IO.puts("  done in #{fmt_s(ms)}")
    %{ctx | phases: ctx.phases ++ [{name, ms}]}
  end

  # 1. users ---------------------------------------------------------------
  defp phase_users(%{users: users, o: o} = ctx) do
    pmap(users, o[:concurrency], fn u ->
      ident = %{
        did: u.did,
        tenant_uuid: u.gid,
        storage_tier: 1,
        token_claims: %{"email" => "#{u.nick}@sim.local", "preferred_username" => u.nick}
      }

      Metrics.measure("user.register", fn -> Registration.complete(ident, u.nick) end)
    end)

    ctx
  end

  # 2. social --------------------------------------------------------------
  defp phase_social(%{users: users, o: o} = ctx) do
    follows = for u <- users, t <- pick(users, u, o[:follows_per_user]), do: {u, t}
    contacts = for u <- users, t <- pick(users, u, o[:contacts_per_user]), do: {u, t}

    pmap(follows, o[:concurrency], fn {u, t} ->
      case Metrics.measure("social.follow", fn -> Follows.follow(me(u), t.did) end) do
        {:ok, _} -> count(ctx, {:followed, t.did})
        _ -> :ok
      end
    end)

    pmap(contacts, o[:concurrency], fn {u, t} ->
      Metrics.measure("social.add_contact", fn -> Contacts.add(me(u), t.did) end)
    end)

    ctx
  end

  # 3. files ---------------------------------------------------------------
  defp phase_files(%{users: users, o: o} = ctx) do
    jobs =
      for u <- users, n <- 1..max(o[:files_per_user], 1)//1, o[:files_per_user] > 0 do
        {u, n, weighted(o[:file_sizes]), if(:rand.uniform() < o[:public_ratio], do: "public", else: "private")}
      end

    pmap(jobs, o[:concurrency], fn {u, n, size, space} ->
      bytes = :crypto.strong_rand_bytes(size)
      meta = %{filename: "sim_#{n}_#{size}.bin", content_type: "application/octet-stream", size_bytes: size}

      case Metrics.measure("file.upload.#{size_label(size)}", fn -> Files.upload(me(u), u.gid, bytes, meta, space: space) end) do
        {:ok, %{commons: "replicated"}} -> count(ctx, :public_replicated)
        {:ok, %{commons: "failed" <> _}} -> count(ctx, :public_failed)
        _ -> :ok
      end

      count(ctx, :blob_bytes, size)
    end)

    # Dedup: the same bytes uploaded twice by one user -> one blob, ref_count 2.
    dup_users = Enum.take(users, o[:dup_users])

    pmap(dup_users, o[:concurrency], fn u ->
      bytes = :crypto.strong_rand_bytes(64 * @kb)
      meta = %{filename: "dup.bin", content_type: "application/octet-stream", size_bytes: 64 * @kb}
      _ = Metrics.measure("file.upload.dup_first", fn -> Files.upload(me(u), u.gid, bytes, meta) end)

      case Metrics.measure("file.upload.dup_second", fn -> Files.upload(me(u), u.gid, bytes, meta) end) do
        {:ok, %{ref_count: rc}} when rc >= 2 -> count(ctx, :dedup_ok)
        other -> put_sample(ctx, :dedup_bad, {u.did, other})
      end
    end)

    ctx
  end

  # 4. direct messages -----------------------------------------------------
  defp phase_dm(%{users: users, o: o} = ctx) do
    jobs =
      for u <- users, p <- pick(users, u, o[:dm_peers_per_user]), n <- 1..o[:dms_per_peer]//1, o[:dms_per_peer] > 0 do
        {u, p, n, :rand.uniform() < o[:attachment_ratio]}
      end

    # Shuffle so many conversations are written at the same time.
    pmap(Enum.shuffle(jobs), o[:concurrency], fn {u, p, n, attach?} -> send_dm(ctx, u, p, n, attach?) end)
    ctx
  end

  defp send_dm(ctx, u, p, n, attach?) do
    attrs =
      if attach? do
        size = weighted(ctx.o[:attachment_sizes])
        bytes = :crypto.strong_rand_bytes(size)
        meta = %{filename: "att_#{n}.bin", content_type: "application/octet-stream", size_bytes: size}
        count(ctx, :blob_bytes, size)

        case Metrics.measure("dm.attachment_upload.#{size_label(size)}", fn -> Files.upload(me(u), u.gid, bytes, meta) end) do
          {:ok, %{content_cas: cas}} -> %{object_cas: cas, object_name: meta.filename, object_mime: meta.content_type}
          _ -> nil
        end
      else
        %{content: "sim message #{n} from #{u.nick} at #{System.os_time(:microsecond)}"}
      end

    op = if attach?, do: "dm.send_attachment", else: "dm.send_text"

    if attrs do
      case Metrics.measure(op, fn -> Messages.send_dm(me(u), p.did, attrs) end) do
        {:ok, %{"status" => status} = msg} ->
          count(ctx, {:sent, u.did, p.did})
          if status == "undelivered", do: count(ctx, :dm_not_delivered)
          if attach?, do: put_sample(ctx, :attachment, {p, Key.dm_thread(u.did), msg["msg_id"]})

        {:ok, msg} ->
          count(ctx, {:sent, u.did, p.did})
          if attach?, do: put_sample(ctx, :attachment, {p, Key.dm_thread(u.did), msg["msg_id"]})

        _ ->
          :ok
      end
    end
  end

  # 5. hot user ------------------------------------------------------------
  defp phase_fanin(%{users: [hot | rest], o: o} = ctx) do
    if o[:fanin] do
      # Everybody at once: concurrency = number of senders.
      pmap(rest, max(length(rest), 1), fn u ->
        case Metrics.measure("fanin.send_to_hot_user", fn ->
               Messages.send_dm(me(u), hot.did, %{content: "hello hot user from #{u.nick}"})
             end) do
          {:ok, _} -> count(ctx, {:sent, u.did, hot.did})
          _ -> :ok
        end
      end)
    end

    ctx
  end

  # 6. circles -------------------------------------------------------------
  defp phase_circles(%{users: users, o: o} = ctx) do
    owners = Enum.take(users, min(o[:circles], length(users)))

    circles =
      owners
      |> pmap(o[:concurrency], fn owner ->
        case Metrics.measure("circle.create", fn ->
               Circles.create(me(owner), "Sim circle of #{owner.nick}", %{join_approval_required: false})
             end) do
          {:ok, circle} -> {owner, circle}
          _ -> nil
        end
      end)
      # keep only real {owner, circle} results (a failed create is nil or {:error, _})
      |> Enum.filter(&match?({%{did: _}, %{"circle_id" => _}}, &1))

    memberships =
      for {owner, circle} <- circles, m <- pick(users, owner, o[:circle_size] - 1), do: {m, owner, circle}

    pmap(memberships, o[:concurrency], fn {m, _owner, circle} ->
      Metrics.measure("circle.join", fn -> Members.join(me(m), circle["invite_code"]) end)
    end)

    # Members as the circle sees them now (the owner included).
    rosters =
      for {owner, circle} <- circles do
        members =
          case Members.list(owner.did, circle["circle_id"]) do
            {:ok, rows} -> for %{"status" => "active", "member_did" => d} <- rows, do: d
            _ -> [owner.did]
          end

        {circle["circle_id"], owner, members}
      end

    jobs =
      for {cid, _owner, members} <- rosters, did <- members, n <- 1..o[:circle_msgs_per_member]//1, o[:circle_msgs_per_member] > 0,
          do: {cid, find_user(users, did), n}

    pmap(Enum.shuffle(jobs), o[:concurrency], fn {cid, u, n} ->
      case Metrics.measure("circle.send_message", fn ->
             CircleMessages.send(me(u), cid, %{content: "circle msg #{n} from #{u.nick}"})
           end) do
        {:ok, _} -> count(ctx, {:circle_sent, cid, u.did})
        _ -> :ok
      end
    end)

    put_state(ctx, :rosters, rosters)
  end

  # 7. reads ---------------------------------------------------------------
  defp phase_reads(%{users: users, o: o} = ctx) do
    rosters = get_state(ctx, :rosters, [])

    jobs = for round <- 1..o[:read_rounds]//1, o[:read_rounds] > 0, u <- users, do: {round, u}

    pmap(jobs, o[:concurrency], fn {_round, u} ->
      Metrics.measure("read.chat_list", fn -> Threads.list(u.did) end)
      Metrics.measure("read.unread_total", fn -> Threads.unread_total(u.did) end)
      Metrics.measure("read.notifications", fn -> Notifications.list(u.did, limit: 50) end)
      Metrics.measure("read.files_private", fn -> Files.list_recent(me(u), u.gid) end)
      Metrics.measure("read.my_circles", fn -> Circles.my_circles(u.did) end)
      Metrics.measure("read.profile", fn -> Profile.get(me(u), u.gid) end)

      case pick(users, u, 1) do
        [peer] -> Metrics.measure("read.conversation_50", fn -> Messages.list_thread(u.did, Key.dm_thread(peer.did), limit: 50) end)
        _ -> :ok
      end

      for {cid, _owner, members} <- rosters, u.did in members do
        Metrics.measure("read.circle_messages_50", fn -> CircleMessages.list(u.did, cid, limit: 50) end)
      end
    end)

    attachments = get_samples(ctx, :attachment)

    pmap(Enum.take(attachments, 50), o[:concurrency], fn {p, thread, msg_id} ->
      Metrics.measure("read.attachment_url", fn -> Messages.blob_url(me(p), thread, msg_id) end)
    end)

    pmap(Enum.take(attachments, o[:save_to_vault]), o[:concurrency], fn {p, thread, msg_id} ->
      Metrics.measure("file.save_to_vault", fn -> Messages.save_to_vault(me(p), thread, msg_id) end)
    end)

    ctx
  end

  # 8. correctness ---------------------------------------------------------
  defp phase_checks(%{users: users, o: o} = ctx) do
    pairs =
      ctx
      |> counters()
      |> Enum.flat_map(fn
        {{:sent, from, to}, n} -> [{from, to, n}]
        _ -> []
      end)
      |> Enum.shuffle()
      |> Enum.take(o[:check_pairs])

    # outbox(sender) and inbox(recipient) must both hold every sent message,
    # and the recipient's unread counter must match (nothing was marked read).
    dm =
      pmap(pairs, o[:concurrency], fn {from, to, n} ->
        out = count_rows(from, "outbox", Key.dm_thread(to))
        inn = count_rows(to, "inbox", Key.dm_thread(from))

        unread =
          case Threads.get(to, Key.dm_thread(from)) do
            {:ok, t} -> t["unread_count"] || 0
            _ -> 0
          end

        {n, out, inn, unread}
      end)

    dm_ok = Enum.count(dm, fn {n, out, inn, _} -> out == n and inn == n end)
    unread_ok = Enum.count(dm, fn {n, _, _, unread} -> unread == n end)

    # circle: every member's inbox holds the messages of all OTHER members
    rosters = get_state(ctx, :rosters, [])
    sent = counters(ctx)

    circle =
      for {cid, _owner, members} <- rosters, member <- Enum.take(members, 10) do
        expected =
          members
          |> Enum.reject(&(&1 == member))
          |> Enum.map(&Map.get(sent, {:circle_sent, cid, &1}, 0))
          |> Enum.sum()

        {expected, count_rows(member, "inbox", Key.circle_thread(cid))}
      end

    circle_ok = Enum.count(circle, fn {e, got} -> e == got end)

    # follow notifications: one per follower, in the target's "sys" thread
    follow_checks =
      users
      |> Enum.take(20)
      |> Enum.map(fn u ->
        expected = Map.get(sent, {:followed, u.did}, 0)

        got =
          case rows(u.did, "inbox", "sys") do
            :error -> -1
            list -> Enum.count(list, &(&1["category"] == "follow"))
          end

        {expected, got}
      end)

    follow_ok = Enum.count(follow_checks, fn {e, got} -> got >= e end)

    checks = [
      check("DM outbox = inbox = sent (#{length(dm)} pairs)", dm_ok, length(dm)),
      check("DM unread counter = received", unread_ok, length(dm)),
      check("circle member inbox = messages of others", circle_ok, length(circle)),
      check("follow notifications delivered", follow_ok, length(follow_checks)),
      check("CAS dedup (same file twice -> ref_count 2)", Map.get(sent, :dedup_ok, 0), o[:dup_users]),
      %{name: "public uploads copied to Postgres", passed: Map.get(sent, :public_replicated, 0),
        total: Map.get(sent, :public_replicated, 0) + Map.get(sent, :public_failed, 0),
        ok: Map.get(sent, :public_failed, 0) == 0}
    ]

    checks = checks ++ [check("DMs reported undelivered (must be 0)", Map.get(sent, :dm_not_delivered, 0), 0)]
    Enum.each(checks, fn c -> IO.puts("  #{if c.ok, do: "PASS", else: "FAIL"}  #{c.name}: #{c.passed}/#{c.total}") end)
    %{ctx | checks: checks}
  end

  # 9. compaction ----------------------------------------------------------
  defp phase_compaction(%{users: [hot | _], o: o} = ctx) do
    thread = hottest_thread(hot.did)
    table = inbox_table_uri(hot.did)
    reads = o[:compaction_reads]

    before_stats = stats(table)
    read_bench("compaction.read_before", hot.did, thread, reads)
    pending = length(LanceCompactor.pending())
    {us, _} = :timer.tc(fn -> LanceCompactor.run_now() end)
    after_stats = stats(table)
    read_bench("compaction.read_after", hot.did, thread, reads)

    IO.puts("  hot inbox: version #{before_stats["version"]} -> #{after_stats["version"]}, rows #{after_stats["rows"]}")
    IO.puts("  compacted #{pending} dirty tables in #{fmt_s(div(us, 1000))}")

    put_state(ctx, :compaction, %{
      hot_inbox_rows: after_stats["rows"],
      hot_inbox_version_before: before_stats["version"],
      hot_inbox_version_after: after_stats["version"],
      tables_compacted: pending,
      compaction_ms: div(us, 1000)
    })
  end

  defp read_bench(op, did, thread, n) do
    for _ <- 1..n//1, n > 0, do: Metrics.measure(op, fn -> Messages.inbox(did, thread, limit: 50) end)
  end

  # 10. storage ------------------------------------------------------------
  defp phase_storage(%{run_id: run_id} = ctx) do
    summary = storage_summary(run_id)

    Enum.each(summary, fn {k, v} -> IO.puts("  #{String.pad_trailing(to_string(k), 26)} #{fmt_storage(k, v)}") end)
    put_state(ctx, :storage, summary)
  end

  # ── storage listing (S3 or local path) ───────────────────────────────

  @doc false
  def storage_summary(run_id) do
    prefix = "did_przma_sim" <> run_id <> "_"
    objects = list_objects(prefix)

    {lance, cas} = Enum.split_with(objects, fn {key, _} -> String.contains?(key, ".lance/") end)

    by_folder =
      Enum.group_by(lance, fn {key, _} ->
        cond do
          String.contains?(key, "/_versions/") -> :lance_versions
          String.contains?(key, "/data/") -> :lance_data
          String.contains?(key, "/_deletions/") -> :lance_deletions
          String.contains?(key, "/_transactions/") -> :lance_transactions
          true -> :lance_other
        end
      end)

    tables = lance |> Enum.map(fn {k, _} -> k |> String.split(".lance/") |> hd() end) |> Enum.uniq() |> length()

    base = %{
      lance_tables: tables,
      lance_objects: length(lance),
      lance_bytes: sum_bytes(lance),
      cas_objects: length(cas),
      cas_bytes: sum_bytes(cas)
    }

    Enum.reduce(by_folder, base, fn {k, objs}, acc ->
      acc |> Map.put(:"#{k}_objects", length(objs)) |> Map.put(:"#{k}_bytes", sum_bytes(objs))
    end)
  end

  defp sum_bytes(objs), do: Enum.reduce(objs, 0, fn {_, size}, acc -> acc + size end)

  # Lance tables live under VAULT_BASE_PATH; CAS blobs under S3_BUCKET (no base prefix).
  defp list_objects(prefix) do
    case base() do
      "s3://" <> rest ->
        {bucket, base_prefix} = split_bucket(rest)
        lance = s3_list(bucket, join_key(base_prefix, prefix))
        cas_bucket = vault_cfg(:s3_bucket)

        cas =
          if cas_bucket == bucket and base_prefix == "",
            do: [],
            else: s3_list(cas_bucket, prefix) |> Enum.reject(fn {k, _} -> String.contains?(k, ".lance/") end)

        Enum.uniq(lance ++ cas)

      local ->
        local
        |> Path.join(prefix <> "*/**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn path -> {Path.relative_to(path, local), File.stat!(path).size} end)
    end
  end

  defp s3_list(bucket, prefix) do
    ExAws.S3.list_objects_v2(bucket, prefix: prefix)
    |> ExAws.stream!(s3_opts())
    |> Enum.map(fn obj -> {obj.key, String.to_integer(to_string(obj.size))} end)
  rescue
    e ->
      Logger.warning("S3 listing failed for #{bucket}/#{prefix}: #{Exception.message(e)}")
      []
  end

  # ── cleanup ──────────────────────────────────────────────────────────

  @doc """
  Removes ONE run's data: S3 objects whose key starts with
  did_przma_sim<run_id>_ (Lance tables + CAS blobs) and its rows in the
  Postgres cas_table (did LIKE 'did:przma:sim<run_id>_%'). Nothing else
  can match those names. Dry run unless confirm: true.

  Not removed (no delete in the doc store): the run's rows in the shared
  directory tables (did_przma-system_directory/...). They only describe
  sim users and do no harm; use a separate test bucket to avoid them.
  """
  def cleanup(run_id, opts \\ []) when is_binary(run_id) do
    unless Regex.match?(~r/^[a-z0-9]{4,16}$/, run_id), do: raise(ArgumentError, "invalid run id")
    prefix = "did_przma_sim" <> run_id <> "_"
    did_like = "did:przma:sim" <> run_id <> "_%"
    objects = list_objects(prefix)

    pg_rows =
      case Przma.CommonsCas.Repo.query("SELECT count(*) FROM cas_table WHERE did LIKE $1", [did_like]) do
        {:ok, %{rows: [[n]]}} -> n
        other -> {:error, other}
      end

    IO.puts("Run #{run_id}: #{length(objects)} S3 objects (#{fmt_bytes(sum_bytes(objects))}), #{inspect(pg_rows)} Postgres rows")

    if Keyword.get(opts, :confirm, false) do
      deleted = delete_objects(prefix)

      pg_deleted =
        case Przma.CommonsCas.Repo.query("DELETE FROM cas_table WHERE did LIKE $1", [did_like]) do
          {:ok, res} -> res.num_rows
          other -> "not deleted: #{inspect(other)}"
        end

      IO.puts("Deleted #{deleted} S3 objects; Postgres rows deleted: #{pg_deleted}.")
      :ok
    else
      IO.puts("Dry run. Call cleanup(\"#{run_id}\", confirm: true) to delete exactly these.")
      :dry_run
    end
  end

  defp delete_objects(prefix) do
    case base() do
      "s3://" <> rest ->
        {bucket, base_prefix} = split_bucket(rest)
        cas_bucket = vault_cfg(:s3_bucket)

        targets =
          [{bucket, join_key(base_prefix, prefix)}] ++
            if(cas_bucket == bucket and base_prefix == "", do: [], else: [{cas_bucket, prefix}])

        Enum.reduce(targets, 0, fn {b, p}, acc ->
          keys = s3_list(b, p) |> Enum.map(&elem(&1, 0))

          keys
          |> Enum.chunk_every(1000)
          |> Enum.each(fn chunk -> ExAws.S3.delete_multiple_objects(b, chunk) |> ExAws.request!(s3_opts()) end)

          acc + length(keys)
        end)

      local ->
        paths = Path.wildcard(Path.join(local, prefix <> "*"))
        Enum.each(paths, &File.rm_rf!/1)
        length(paths)
    end
  end

  # ── report ───────────────────────────────────────────────────────────

  defp build_report(ctx, total_ms) do
    %{
      run_id: ctx.run_id,
      profile: ctx.o[:profile],
      options: Map.new(ctx.o, fn {k, v} -> {k, inspect(v)} end),
      base_path: base(),
      total_seconds: Float.round(total_ms / 1000, 1),
      phases: for({name, ms} <- ctx.phases, do: %{phase: name, seconds: Float.round(ms / 1000, 1)}),
      operations: Metrics.summary(),
      errors: Metrics.errors(),
      checks: ctx.checks,
      compaction: get_state(ctx, :compaction, %{}),
      storage: get_state(ctx, :storage, %{}),
      system: Metrics.system() |> Map.update(:max_mem, 0, &fmt_bytes/1),
      uploaded_blob_bytes: fmt_bytes(Map.get(counters(ctx), :blob_bytes, 0))
    }
  end

  defp print_report(r) do
    IO.puts("\n================ REPORT  run=#{r.run_id}  (#{r.total_seconds}s) ================")
    IO.puts("\nPhases:")
    for p <- r.phases, do: IO.puts("  #{String.pad_trailing(to_string(p.phase), 12)} #{p.seconds}s")

    IO.puts("\nOperations (ms):")
    IO.puts("  " <> row(["operation", "count", "err", "p50", "p95", "p99", "max"]))

    for op <- r.operations do
      IO.puts("  " <> row([op.op, op.count, op.errors, op.p50_ms, op.p95_ms, op.p99_ms, op.max_ms]))
    end

    if r.errors != %{} do
      IO.puts("\nError samples:")
      for {op, samples} <- r.errors, s <- Enum.take(samples, 2), do: IO.puts("  #{op}: #{s}")
    end

    IO.puts("\nChecks:")
    for c <- r.checks, do: IO.puts("  #{if c.ok, do: "PASS", else: "FAIL"}  #{c.name}: #{c.passed}/#{c.total}")

    IO.puts("\nSystem peaks: #{inspect(r.system)}   uploaded blobs: #{r.uploaded_blob_bytes}")
    IO.puts("Compaction: #{inspect(r.compaction)}")
  end

  defp row([op | rest]) do
    String.pad_trailing(to_string(op), 34) <> Enum.map_join(rest, "", &String.pad_leading(to_string(&1), 9))
  end

  defp save_report(report, dir) do
    path = Path.join(dir, "przma_sim_#{report.run_id}.json")

    case File.write(path, Jason.encode!(report, pretty: true)) do
      :ok -> IO.puts("\nReport saved: #{path}\nCleanup later: Przma.Sim.LoadTest.cleanup(\"#{report.run_id}\")")
      {:error, reason} -> IO.puts("Could not save report to #{path}: #{inspect(reason)}")
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp options(opts) do
    profile = Keyword.get(opts, :profile, :smoke)
    base = Map.fetch!(@profiles, profile)
    base |> Keyword.merge(Keyword.drop(opts, [:profile, :run_id, :report_dir])) |> Keyword.put(:profile, profile)
  end

  defp user(run_id, i) do
    nick = "sim#{run_id}_#{String.pad_leading(Integer.to_string(i), 4, "0")}"
    %{i: i, nick: nick, did: "did:przma:" <> nick, gid: uuid()}
  end

  defp me(u), do: %{did: u.did, gid: u.gid, origin_instance_id: nil, portable_grant: nil}

  defp find_user(users, did), do: Enum.find(users, &(&1.did == did))

  # `k` random users other than `u`
  defp pick(users, u, k) when k > 0, do: users |> Enum.reject(&(&1.did == u.did)) |> Enum.take_random(k)
  defp pick(_users, _u, _k), do: []

  defp pmap(items, concurrency, fun) do
    items
    |> Task.async_stream(fn item -> Metrics.safe(fn -> fun.(item) end) end,
      max_concurrency: max(concurrency, 1),
      timeout: :infinity,
      ordered: true
    )
    |> Enum.map(fn {:ok, v} -> v end)
  end

  defp count_rows(did, box, thread) do
    case rows(did, box, thread) do
      :error -> -1
      list -> Enum.count(list, &(&1["status"] != "deleted"))
    end
  end

  # Raw stored rows of one thread (max 1000), read straight through PzdbConnector.
  defp rows(did, box, thread) do
    case PzdbConnector.read_range(me(%{did: did, gid: "read"}), box_uri(did, box), prefix: Key.thread_prefix(thread), limit: 1000) do
      {:ok, json} -> Jason.decode!(json)
      _ -> :error
    end
  end

  defp box_uri(did, box),
    do: PzdbUri.to_string(%PzdbUri{transport: :s3, tenant_id: "read", did: did, namespace: "chat", space: "private", table: box})

  defp inbox_table_uri(did),
    do: LanceDocPath.table_uri(%PzdbUri{transport: :s3, tenant_id: "read", did: did, namespace: "chat", space: "private", table: "inbox"})

  defp stats(table_uri) do
    case PRZMA.PzDb.doc_stats(table_uri) do
      {:ok, s} -> s
      _ -> %{}
    end
  end

  defp hottest_thread(did) do
    case Threads.list(did) do
      {:ok, threads} when threads != [] ->
        threads |> Enum.max_by(&(&1["unread_count"] || 0)) |> Map.get("thread_key")

      _ ->
        "sys"
    end
  end

  defp check(name, passed, total), do: %{name: name, passed: passed, total: total, ok: passed == total}

  # run-wide counters / samples (ETS owned by the run's process)
  defp new_state do
    t = :ets.new(:przma_sim_state, [:public, :set, write_concurrency: true])
    s = :ets.new(:przma_sim_samples, [:public, :bag, write_concurrency: true])
    %{counters: t, samples: s, kv: %{}}
  end

  defp count(ctx, key, by \\ 1), do: :ets.update_counter(ctx.state.counters, key, {2, by}, {key, 0})
  defp counters(ctx), do: Map.new(:ets.tab2list(ctx.state.counters))
  defp put_sample(ctx, key, value), do: :ets.insert(ctx.state.samples, {key, value})
  defp get_samples(ctx, key), do: for({_, v} <- :ets.lookup(ctx.state.samples, key), do: v)
  defp put_state(ctx, key, value), do: put_in(ctx, [:state, :kv, key], value)
  defp get_state(ctx, key, default), do: Map.get(ctx.state.kv, key, default)

  defp weighted(choices) do
    total = choices |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    roll = :rand.uniform(total)

    Enum.reduce_while(choices, 0, fn {size, w}, acc ->
      if roll <= acc + w, do: {:halt, size}, else: {:cont, acc + w}
    end)
  end

  defp avg_size(choices) do
    total = choices |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    choices |> Enum.map(fn {s, w} -> s * w end) |> Enum.sum() |> div(max(total, 1))
  end

  defp size_label(b) when b >= @mb, do: "#{div(b, @mb)}MB"
  defp size_label(b), do: "#{div(b, @kb)}KB"

  defp fmt_storage(k, v) when is_integer(v) do
    if String.ends_with?(to_string(k), "_bytes"), do: fmt_bytes(v), else: to_string(v)
  end

  defp fmt_storage(_k, v), do: inspect(v)

  defp fmt_bytes(b) when is_integer(b) and b >= 1024 * @mb, do: "#{Float.round(b / (1024 * @mb), 2)} GB"
  defp fmt_bytes(b) when is_integer(b) and b >= @mb, do: "#{Float.round(b / @mb, 1)} MB"
  defp fmt_bytes(b) when is_integer(b), do: "#{Float.round(b / @kb, 1)} KB"
  defp fmt_bytes(other), do: inspect(other)

  defp fmt_s(ms), do: "#{Float.round(ms / 1000, 1)}s"

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp random_id, do: :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]) |> to_string()
  end

  defp base, do: Application.get_env(:przma, :vault_base_path, "")

  defp split_bucket(rest) do
    case String.split(rest, "/", parts: 2) do
      [bucket] -> {bucket, ""}
      [bucket, p] -> {bucket, String.trim(p, "/")}
    end
  end

  defp join_key("", prefix), do: prefix
  defp join_key(base, prefix), do: base <> "/" <> prefix

  defp vault_cfg(key), do: Application.get_env(:przma, :vault, []) |> Keyword.get(key)

  # Same S3 settings Cas uses (config :przma, :vault).
  defp s3_opts do
    [
      access_key_id: vault_cfg(:s3_access_key),
      secret_access_key: vault_cfg(:s3_secret_key),
      region: vault_cfg(:s3_region),
      host: (vault_cfg(:s3_endpoint) || "") |> String.replace_prefix("https://", "") |> String.replace_prefix("http://", ""),
      scheme: "https://"
    ]
  end
end
