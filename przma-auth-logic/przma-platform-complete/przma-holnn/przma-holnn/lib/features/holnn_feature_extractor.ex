# lib/features/holnn_feature_extractor.ex
#
# HOLNN Feature Extractor — computes the 446-dimensional input tensor.
#
# 13 signal groups (dimensions must sum to 446):
#
#   Group  1: Calendar Temporal Patterns  (40 dims)
#   Group  2: Vault Domain Activity       (42 dims)
#   Group  3: Practice Adherence          (30 dims)
#   Group  4: Temporal Rhythms            (35 dims)
#   Group  5: Social Engagement           (28 dims)
#   Group  6: Language & Sentiment        (60 dims)
#   Group  7: Physical Signals            (20 dims)
#   Group  8: Knowledge Acquisition       (45 dims)
#   Group  9: Emotional Valence           (40 dims)
#   Group 10: Creative Expression         (25 dims)
#   Group 11: Reflection Depth            (35 dims)
#   Group 12: Relationship Patterns       (28 dims)
#   Group 13: Integration Coherence       (18 dims)
#              ─────────────────────────────────────
#              Total                      446 dims
#
# All features are normalised to [0, 1] before assembly.
# Missing data is filled with 0.5 (neutral/unknown) rather than 0.0 (absence).
# This prevents the model from treating data gaps as FOGGED states.

defmodule PRZMA.HOLNN.FeatureExtractor do
  require Logger

  alias PRZMA.Calendar.NIF
  alias PRZMA.PzDb

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")
  @neutral    0.5   # default when signal is unavailable

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  @doc """
  Extract the 446-dim feature vector for a DID.

  Returns {:ok, %Nx.Tensor{}} with shape {1, 446} ready for HOLNN inference,
  or {:ok, feature_map} with labelled dimensions for debugging/inspection.

  opts:
    :window_days — lookback window in days (default: 30)
    :format      — :tensor (default) | :map | :list
  """
  def extract(did, opts \\ []) do
    window_days = opts[:window_days] || 30
    format      = opts[:format]      || :tensor

    now_us   = System.os_time(:microsecond)
    start_us = now_us - (window_days * 86_400 * 1_000_000)

    Logger.debug("Extracting HOLNN features", did: did, window_days: window_days)

    # Fetch all signals in parallel (non-blocking)
    [cal_task, vault_task, lang_task] = [
      Task.async(fn -> calendar_signals(did, start_us, now_us) end),
      Task.async(fn -> vault_signals(did, start_us, now_us) end),
      Task.async(fn -> language_signals(did, start_us, now_us) end),
    ]

    cal   = Task.await(cal_task,   10_000) |> ok_or_neutral(40 + 30 + 35 + 28)
    vault = Task.await(vault_task, 10_000) |> ok_or_neutral(42 + 20 + 25 + 35 + 28)
    lang  = Task.await(lang_task,  10_000) |> ok_or_neutral(60 + 45 + 40 + 18)

    # Assemble all 446 dimensions in group order
    features = List.flatten([
      group1_calendar_temporal(cal, 40),
      group2_vault_domain_activity(vault, 42),
      group3_practice_adherence(cal, 30),
      group4_temporal_rhythms(cal, 35),
      group5_social_engagement(cal, 28),
      group6_language_sentiment(lang, 60),
      group7_physical_signals(vault, 20),
      group8_knowledge_acquisition(vault, 45),
      group9_emotional_valence(vault, 40),
      group10_creative_expression(vault, 25),
      group11_reflection_depth(vault, 35),
      group12_relationship_patterns(cal, 28),
      group13_integration_coherence(cal, vault, lang, 18),
    ])

    # Validate dimension count
    unless length(features) == 446 do
      Logger.error("Feature dimension mismatch",
        expected: 446, got: length(features))
    end

    # Clamp all values to [0, 1]
    features = Enum.map(features, fn f ->
      f |> max(0.0) |> min(1.0)
    end)

    case format do
      :tensor ->
        tensor = Nx.tensor([features], type: :f32)
        {:ok, tensor}

      :list ->
        {:ok, features}

      :map ->
        labelled = features
          |> Enum.with_index()
          |> Enum.map(fn {v, i} -> {"dim_#{i}", v} end)
          |> Enum.into(%{})
        {:ok, labelled}
    end
  end

  # ── GROUP 1: Calendar Temporal Patterns (40) ───────────────────────────────

  defp group1_calendar_temporal(cal, expected) do
    %{
      dist: dist,
      meeting_patterns: mp,
    } = cal

    by_hour = Map.get(dist, "by_hour", [])
    by_dow  = Map.get(dist, "by_day_of_week", [])
    total   = max(Map.get(dist, "total_events", 0), 1)

    # Events by time-of-day block (4 dims: morning/afternoon/evening/night)
    morning   = sum_hours(by_hour, 6..11)  / total
    afternoon = sum_hours(by_hour, 12..17) / total
    evening   = sum_hours(by_hour, 18..21) / total
    night     = sum_hours(by_hour, 22..5)  / total

    # Meeting density per weekday (5 dims)
    weekday_events = for d <- 1..5, do: dow_events(by_dow, d) / total

    # Weekend activity (2 dims)
    saturday = dow_events(by_dow, 6) / total
    sunday   = dow_events(by_dow, 0) / total

    # Focus and meeting metrics (5 dims)
    focus_ratio     = Map.get(mp, "focus_block_ratio", @neutral)
    btb_ratio       = min(Map.get(mp, "back_to_back_count", 0) / max(total, 1), 1.0)
    avg_dur_norm    = min(Map.get(mp, "avg_duration_mins", 0) / 120.0, 1.0)
    practice_ratio  = (Map.get(dist, "by_category", %{})["PRACTICE"] || 0) / total
    meeting_ratio   = (Map.get(dist, "by_category", %{})["MEETING"]  || 0) / total

    # Duration buckets (5 dims: <30, 30-60, 60-120, 120-240, >240 min)
    avg_m = Map.get(mp, "avg_duration_mins", 60)
    dur_buckets = [
      sigmoid_bucket(avg_m, 0, 30),
      sigmoid_bucket(avg_m, 30, 60),
      sigmoid_bucket(avg_m, 60, 120),
      sigmoid_bucket(avg_m, 120, 240),
      sigmoid_bucket(avg_m, 240, 999),
    ]

    # Activity trend (3 dims: increasing/stable/decreasing)
    trend = trend_3dims(Map.get(cal, :weekly_trend, 0))

    # Additional temporal signals (11 dims)
    milestone_ratio  = (Map.get(dist, "by_category", %{})["MILESTONE"] || 0) / total
    appt_ratio       = (Map.get(dist, "by_category", %{})["APPOINTMENT"] || 0) / total
    study_ratio      = (Map.get(dist, "by_category", %{})["STUDY"]  || 0) / total
    activity_ratio   = (Map.get(dist, "by_category", %{})["ACTIVITY"] || 0) / total
    block_ratio      = (Map.get(dist, "by_category", %{})["BLOCK"]  || 0) / total
    recurrence_ratio = Map.get(cal, :recurrence_ratio, @neutral)
    diversity        = category_diversity(Map.get(dist, "by_category", %{}), total)
    peak_hour_norm   = Map.get(mp, "peak_meeting_hour", 10) / 23.0
    empty_day_ratio  = Map.get(cal, :empty_day_ratio, @neutral)
    late_ratio       = sum_hours(by_hour, 22..23) / total
    early_ratio      = sum_hours(by_hour, 5..7)   / total

    pad_to([
      morning, afternoon, evening, night,      # 4
      weekday_events,                          # 5
      saturday, sunday,                        # 2
      focus_ratio, btb_ratio, avg_dur_norm, practice_ratio, meeting_ratio,  # 5
      dur_buckets,                             # 5
      trend,                                   # 3
      milestone_ratio, appt_ratio, study_ratio, activity_ratio, block_ratio, # 5
      recurrence_ratio, diversity, peak_hour_norm,                           # 3
      empty_day_ratio, late_ratio, early_ratio,                              # 3
      @neutral, @neutral, @neutral, @neutral, @neutral,                      # 5 padding
    ], expected)
  end

  # ── GROUP 2: Vault Domain Activity (42) ────────────────────────────────────

  defp group2_vault_domain_activity(vault, expected) do
    domains  = ~w(my_health my_day my_people my_thoughts who_i_am what_i_learned quiet_moments my_practices)
    entries  = Map.get(vault, :entries, %{})
    max_freq = max(Enum.map(domains, fn d -> get_in(entries, [d, :count]) || 0 end) |> Enum.max(), 1)

    # Frequency per domain (8 dims)
    freq = Enum.map(domains, fn d -> ((get_in(entries, [d, :count]) || 0) / max_freq) end)

    # Average entry length per domain (8 dims)
    len = Enum.map(domains, fn d ->
      min((get_in(entries, [d, :avg_length]) || 100) / 1000.0, 1.0)
    end)

    # Days since last entry per domain (8 dims) — normalised to 30 days
    recency = Enum.map(domains, fn d ->
      days = get_in(entries, [d, :days_since_last]) || 30
      1.0 - min(days / 30.0, 1.0)  # 1=recent, 0=stale
    end)

    # Quality score per domain (8 dims)
    quality = Enum.map(domains, fn d ->
      get_in(entries, [d, :quality_score]) || @neutral
    end)

    # Cross-domain activity (3 dims)
    cross_ref_freq = Map.get(vault, :cross_ref_frequency, @neutral)
    update_recency = Map.get(vault, :update_recency,       @neutral)
    total_norm     = min(Map.get(vault, :total_entries, 0) / 1000.0, 1.0)

    # Sentiment trend (3 dims)
    sentiment = Map.get(vault, :sentiment_trend, [@neutral, @neutral, @neutral])

    pad_to([
      freq,          # 8
      len,           # 8
      recency,       # 8
      quality,       # 8
      cross_ref_freq, update_recency, total_norm,  # 3
      sentiment,     # 3
      @neutral, @neutral, @neutral, @neutral,       # 4 padding
    ], expected)
  end

  # ── GROUP 3: Practice Adherence (30) ───────────────────────────────────────

  defp group3_practice_adherence(cal, expected) do
    practices = Map.get(cal, :practices, %{})
    filters   = ~w(body senses mind heart ego knowledge detachment)

    # Current streak per filter-associated practice (7 dims)
    streaks = Enum.map(filters, fn f ->
      min(Map.get(practices, "#{f}_current_streak", 0) / 30.0, 1.0)
    end)

    # Longest streak (7 dims)
    longest = Enum.map(filters, fn f ->
      min(Map.get(practices, "#{f}_longest_streak", 0) / 90.0, 1.0)
    end)

    # 7-day completion rate (7 dims)
    rate7 = Enum.map(filters, fn f ->
      Map.get(practices, "#{f}_rate7",  @neutral)
    end)

    # 30-day completion rate (7 dims)
    rate30 = Enum.map(filters, fn f ->
      Map.get(practices, "#{f}_rate30", @neutral)
    end)

    # Days since Heart and Body practice (2 dims — most critical)
    heart_days = Map.get(practices, "heart_days_since", 7)
    body_days  = Map.get(practices, "body_days_since",  7)

    pad_to([
      streaks,                                   # 7
      longest,                                   # 7
      rate7,                                     # 7
      rate30,                                    # 7
      1.0 - min(heart_days / 7.0, 1.0),         # 1
      1.0 - min(body_days  / 7.0, 1.0),         # 1
    ], expected)
  end

  # ── GROUP 4-13: Remaining groups ───────────────────────────────────────────
  # Each fills its target dimension count with computed signals + @neutral padding.

  defp group4_temporal_rhythms(cal, expected),      do: neutral_group(expected)
  defp group5_social_engagement(cal, expected),     do: neutral_group(expected)
  defp group7_physical_signals(vault, expected),    do: extract_physical(vault, expected)
  defp group8_knowledge_acquisition(vault, expected), do: extract_knowledge(vault, expected)
  defp group9_emotional_valence(vault, expected),   do: extract_emotional(vault, expected)
  defp group10_creative_expression(vault, expected), do: neutral_group(expected)
  defp group11_reflection_depth(vault, expected),   do: extract_reflection(vault, expected)
  defp group12_relationship_patterns(cal, expected), do: neutral_group(expected)

  defp group6_language_sentiment(lang, expected) do
    # Filter-specific vocabulary scores (7 × 5 = 35 dims)
    filter_vocab = for f <- ~w(body senses mind heart ego knowledge detachment) do
      for w <- 1..5, do: Map.get(lang, "#{f}_word#{w}", @neutral)
    end |> List.flatten()

    # Sentiment (3 dims)
    positive = Map.get(lang, :positive, @neutral)
    negative = Map.get(lang, :negative, @neutral)
    neutral  = Map.get(lang, :neutral_sentiment, @neutral)

    # Additional language signals (22 dims — padded)
    insight_markers   = Map.get(lang, :insight_markers,   @neutral)
    gratitude_markers = Map.get(lang, :gratitude_markers, @neutral)
    struggle_markers  = Map.get(lang, :struggle_markers,  @neutral)
    growth_markers    = Map.get(lang, :growth_markers,    @neutral)
    clarity_markers   = Map.get(lang, :clarity_markers,   @neutral)

    pad_to([
      filter_vocab,   # 35
      positive, negative, neutral,  # 3
      insight_markers, gratitude_markers, struggle_markers,
      growth_markers, clarity_markers,     # 5
      # Remaining 17 dims padded with neutral
    ], expected)
  end

  defp group13_integration_coherence(cal, vault, lang, expected) do
    # Overall coherence signal (1)
    coherence = compute_coherence_score(cal, vault, lang)

    # Per-filter integration (7 dims — how integrated each filter is)
    filter_integration = for _f <- 1..7, do: @neutral

    # Values-behavior alignment (1)
    alignment = Map.get(vault, :values_alignment, @neutral)

    pad_to([
      coherence,
      filter_integration,  # 7
      alignment,
      # Remaining 9 dims
    ], expected)
  end

  # ── SIGNAL FETCHERS ────────────────────────────────────────────────────────

  defp calendar_signals(did, start_us, now_us) do
    with {:ok, dist_json}    <- NIF.time_distribution(@base_path, did, start_us, now_us),
         {:ok, mp_json}      <- NIF.meeting_patterns(@base_path, did, start_us, now_us) do
      dist = Jason.decode!(dist_json)
      mp   = Jason.decode!(mp_json)

      {:ok, %{
        dist:             dist,
        meeting_patterns: mp,
        practices:        %{},       # Phase final: query practices per filter
        weekly_trend:     0.0,       # Phase final: compute from 4-week rolling
        recurrence_ratio: @neutral,
        empty_day_ratio:  @neutral,
      }}
    else
      _ -> {:error, :calendar_unavailable}
    end
  end

  defp vault_signals(did, _start_us, _now_us) do
    # Query vault entry stats per domain
    # Phase final: DuckDB query on vault/core/entries.lance grouped by domain
    {:ok, %{
      entries:           %{},
      total_entries:     0,
      cross_ref_frequency: @neutral,
      update_recency:    @neutral,
      sentiment_trend:   [@neutral, @neutral, @neutral],
      values_alignment:  @neutral,
    }}
  end

  defp language_signals(did, start_us, now_us) do
    # Analyse vault entry text for filter-specific vocabulary
    # Phase final: TF-IDF style scoring over recent vault entries
    {:ok, %{
      positive:        @neutral,
      negative:        @neutral,
      neutral_sentiment: @neutral,
      insight_markers:   @neutral,
      gratitude_markers: @neutral,
      struggle_markers:  @neutral,
      growth_markers:    @neutral,
      clarity_markers:   @neutral,
    }}
  end

  # ── PHYSICAL, KNOWLEDGE, EMOTIONAL, REFLECTION EXTRACTORS ────────────────

  defp extract_physical(vault, expected) do
    health = get_in(vault, [:entries, "my_health"]) || %{}
    [
      Map.get(health, :frequency, @neutral),
      Map.get(health, :quality_score, @neutral),
      Map.get(health, :energy_trend, @neutral),
      Map.get(health, :mood_trend,   @neutral),
    ]
    |> pad_to(expected)
  end

  defp extract_knowledge(vault, expected) do
    learned = get_in(vault, [:entries, "what_i_learned"]) || %{}
    [
      Map.get(learned, :frequency,    @neutral),
      Map.get(learned, :quality_score,@neutral),
      Map.get(learned, :recency,      @neutral),
      1.0 - min((Map.get(learned, :days_since_last, 30)) / 30.0, 1.0),
    ]
    |> pad_to(expected)
  end

  defp extract_emotional(vault, expected) do
    thoughts = get_in(vault, [:entries, "my_thoughts"]) || %{}
    [
      Map.get(vault, :sentiment_trend, [@neutral, @neutral, @neutral]),
      Map.get(thoughts, :mood_score, @neutral),
      Map.get(thoughts, :energy_score, @neutral),
    ]
    |> List.flatten()
    |> pad_to(expected)
  end

  defp extract_reflection(vault, expected) do
    quiet = get_in(vault, [:entries, "quiet_moments"]) || %{}
    [
      Map.get(quiet, :frequency,    @neutral),
      Map.get(quiet, :quality_score,@neutral),
      Map.get(quiet, :recency,      @neutral),
    ]
    |> pad_to(expected)
  end

  # ── HELPERS ────────────────────────────────────────────────────────────────

  defp ok_or_neutral({:ok, v}, _n), do: v
  defp ok_or_neutral({:error, _}, n), do: Enum.map(1..n, fn _ -> @neutral end)
  defp ok_or_neutral(v, _) when is_map(v), do: v

  defp neutral_group(n), do: List.duplicate(@neutral, n)

  defp pad_to(list, target) when is_list(list) do
    flat = List.flatten(list) |> Enum.map(&to_float/1)
    len  = length(flat)
    cond do
      len == target -> flat
      len <  target -> flat ++ List.duplicate(@neutral, target - len)
      len >  target -> Enum.take(flat, target)
    end
  end

  defp to_float(v) when is_float(v),   do: v
  defp to_float(v) when is_integer(v), do: v / 1.0
  defp to_float(v) when is_nil(v),     do: @neutral
  defp to_float(_),                    do: @neutral

  defp sum_hours(by_hour, range) when is_list(by_hour) do
    range_list = Enum.to_list(range)
    by_hour
    |> Enum.filter(fn h -> h["hour"] in range_list end)
    |> Enum.reduce(0, fn h, acc -> acc + (h["event_count"] || 0) end)
    |> to_float()
  end
  defp sum_hours(_, _), do: 0.0

  defp dow_events(by_dow, dow) when is_list(by_dow) do
    day_names = ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
    target    = Enum.at(day_names, dow)
    Enum.find_value(by_dow, 0, fn d ->
      if d["day_name"] == target, do: d["event_count"] || 0
    end) |> to_float()
  end
  defp dow_events(_, _), do: 0.0

  defp sigmoid_bucket(value, low, high) do
    if value >= low and value < high, do: 1.0, else: 0.0
  end

  defp trend_3dims(trend) when trend > 0.1, do: [1.0, 0.0, 0.0]
  defp trend_3dims(trend) when trend < -0.1, do: [0.0, 0.0, 1.0]
  defp trend_3dims(_), do: [0.0, 1.0, 0.0]

  defp category_diversity(by_category, total) when total > 0 do
    n        = map_size(by_category)
    if n == 0, do: 0.0,
    else: Enum.reduce(by_category, 0.0, fn {_, count}, acc ->
      p = count / total
      if p > 0, do: acc - p * :math.log2(p), else: acc
    end) / :math.log2(max(n, 2))
  end
  defp category_diversity(_, _), do: @neutral

  defp compute_coherence_score(cal, vault, _lang) do
    practice_ratio = Map.get(cal, :practice_ratio, @neutral)
    vault_activity = if is_map(vault) and map_size(vault) > 0, do: 0.6, else: @neutral
    (practice_ratio + vault_activity) / 2.0
  end
end
