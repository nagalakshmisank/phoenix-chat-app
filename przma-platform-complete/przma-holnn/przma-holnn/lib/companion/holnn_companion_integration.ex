# lib/companion/holnn_companion_integration.ex
#
# HOLNN ↔ Companion Service Integration
#
# This module connects the HOLNN perception engine to the companion service.
# Every companion response is shaped by the user's current filter state.
#
# Key integration points:
#
#   1. CompanionContext — enriches the context assembled for every agent session
#      with the user's current filter states and Sapience Index.
#
#   2. ResponseTone — adjusts how the companion responds based on which
#      filters are FOGGED. A FOGGED Mind filter gets simpler language.
#      A FOGGED Heart filter gets more warmth. A FOGGED Ego filter gets
#      more service-oriented framing.
#
#   3. Practice Recommendations — surfaces relevant practices based on
#      which filters have been FOGGED longest.
#
#   4. Insight Timing — the Arc Engine only surfaces insights when the
#      user's readiness (Sapience Index) is high enough. Below S=40,
#      insights are held back — the user is not ready to integrate them.
#
#   5. Memory Formation — high-salience events that coincide with clear
#      Heart filter form deeper companion memories.

defmodule PRZMA.HOLNN.CompanionIntegration do
  require Logger

  alias PRZMA.HOLNN.{Inference, CheckIn}
  alias PRZMA.PzDb

  # Minimum Sapience Index before surfacing deep insights
  @insight_threshold 40.0
  # Minimum Heart filter score before relationship insights are shared
  @heart_threshold   0.55

  # ── CONTEXT ENRICHMENT ─────────────────────────────────────────────────────

  @doc """
  Enrich a companion context map with HOLNN perception state.
  Called by CompanionContext.assemble/2 before every agent session.
  Returns the context map with :perception field added.
  """
  def enrich_context(context, did) do
    perception = fetch_perception_state(did)
    Map.put(context, :perception, perception)
  end

  defp fetch_perception_state(did) do
    # Read latest snapshot — never block companion for inference
    case PzDb.query(
      "pzdb://#{did}/companion/core/sapience_snapshots/placeholder",
      filter: "deleted_at IS NULL",
      limit: 1
    ) do
      {:ok, %{"records" => [record | _]}} ->
        filter_states = parse_filter_states(record["filter_states_json"])
        %{
          sapience_index:  record["sapience_index"] || 0.0,
          sapience_band:   band_from_index(record["sapience_index"] || 0.0),
          filter_states:   filter_states,
          pb_accumulator:  record["pb_accumulator"] || 0.0,
          fogged_filters:  fogged_filters(filter_states),
          clear_filters:   clear_filters(filter_states),
          heart_state:     get_in(filter_states, ["heart", "state"]) || "unknown",
          snapshot_age_hours: snapshot_age_hours(record["snapshot_at"]),
          ready_for_insights: (record["sapience_index"] || 0.0) >= @insight_threshold,
        }
      _ ->
        default_perception()
    end
  end

  # ── RESPONSE TONE GUIDANCE ─────────────────────────────────────────────────

  @doc """
  Generate tone guidance for a companion agent based on current filter states.
  This is added to DNA Layer 2 (User Context) in the prompt builder.
  """
  def tone_guidance(did) do
    state = fetch_perception_state(did)
    fogged = state.fogged_filters

    guidance_lines = []

    guidance_lines = if "mind" in fogged do
      ["Use simple, clear language. Avoid dense concepts. The user's Mind filter is FOGGED." | guidance_lines]
    else
      guidance_lines
    end

    guidance_lines = if "heart" in fogged do
      ["Be especially warm and compassionate. The user's Heart filter is FOGGED — they may feel closed off or disconnected." | guidance_lines]
    else
      guidance_lines
    end

    guidance_lines = if "ego" in fogged do
      ["Frame responses around service and contribution, not achievement or comparison. The user's Ego filter is FOGGED." | guidance_lines]
    else
      guidance_lines
    end

    guidance_lines = if "body" in fogged do
      ["Acknowledge physical reality first. Ground the conversation in the body before moving to mind. Body filter is FOGGED." | guidance_lines]
    else
      guidance_lines
    end

    guidance_lines = if "detachment" in fogged do
      ["Avoid adding more complexity. Offer space and simplicity. Detachment filter is FOGGED — the user may be grasping." | guidance_lines]
    else
      guidance_lines
    end

    # High Sapience — more depth is welcome
    guidance_lines = if state.sapience_index >= 70.0 do
      ["The user is in a clear, receptive state (S=#{round(state.sapience_index)}). Depth and nuance are welcome." | guidance_lines]
    else
      guidance_lines
    end

    case guidance_lines do
      [] -> ""
      lines -> "=== PERCEPTION GUIDANCE ===\n" <> Enum.join(Enum.reverse(lines), "\n")
    end
  end

  # ── PRACTICE RECOMMENDATIONS ───────────────────────────────────────────────

  @doc """
  Recommend practices based on which filters have been FOGGED longest.
  Returns a prioritised list of practice recommendations.
  """
  def recommend_practices(did) do
    state = fetch_perception_state(did)
    fogged = state.fogged_filters
    prompts = CheckIn.filter_prompts()

    # Prioritise Heart first (gateway), then by score (most fogged first)
    priority_order = if "heart" in fogged do
      [:heart | (state.fogged_filters -- ["heart"]) |> Enum.map(&String.to_atom/1)]
    else
      state.fogged_filters |> Enum.map(&String.to_atom/1)
    end

    Enum.flat_map(priority_order, fn filter ->
      case Map.get(prompts, filter) do
        nil -> []
        prompt ->
          Enum.map(prompt[:practices] || [], fn practice ->
            %{
              filter:    filter,
              practice:  practice,
              reason:    "Your #{filter} filter is FOGGED. #{prompt[:fogged_sign]}",
              urgency:   if(filter == :heart, do: :high, else: :medium),
            }
          end)
      end
    end)
    |> Enum.take(3)  # Top 3 recommendations
  end

  # ── INSIGHT TIMING GUARD ───────────────────────────────────────────────────

  @doc """
  Check whether the user is ready to receive a deep insight.
  Returns :ready | {:not_ready, reason}
  """
  def insight_readiness(did) do
    state = fetch_perception_state(did)

    cond do
      state.sapience_index < @insight_threshold ->
        {:not_ready, "Sapience Index is #{round(state.sapience_index)}/100. " <>
          "Insights are held for you until you reach #{@insight_threshold}. " <>
          "Focus on practices to raise your clarity."}

      state.heart_state == "fogged" ->
        {:not_ready, "Your Heart filter is FOGGED. Insights land more deeply when the Heart is open. " <>
          "Try heart coherence breathing before revisiting this."}

      true ->
        :ready
    end
  end

  # ── MEMORY FORMATION WEIGHT ────────────────────────────────────────────────

  @doc """
  Compute the memory salience boost when Heart filter is clear.
  Events that occur during Heart clarity form deeper companion memories.
  """
  def memory_salience_boost(did) do
    state = fetch_perception_state(did)
    heart_score = get_in(state, [:filter_states, "heart", "score"]) || 0.5

    # Heart score directly boosts memory formation salience
    # Clear Heart (1.0) = 30% salience boost
    # Fogged Heart (0.0) = no boost
    heart_score * 0.3
  end

  # ── ARC ENGINE INTEGRATION ────────────────────────────────────────────────

  @doc """
  Filters the Arc Engine's surfaced resources through the insight readiness gate.
  If not ready, holds back deep insights but passes through practical items.
  """
  def filter_arc_resources(did, resources) when is_list(resources) do
    case insight_readiness(did) do
      :ready ->
        resources  # All resources surfaced

      {:not_ready, reason} ->
        # Hold back resources tagged as insights or deep reflections
        {holdback, passthrough} = Enum.split_with(resources, fn r ->
          r[:depth] in [:insight, :deep_reflection, :shadow_work]
        end)

        if length(holdback) > 0 do
          Logger.debug("Arc Engine: holding #{length(holdback)} insights for #{did}",
            reason: reason)
        end

        passthrough
    end
  end

  # ── SAPIENCE TREND ────────────────────────────────────────────────────────

  @doc """
  Compute the 30-day Sapience Index trend for a DID.
  Returns %{trend: :rising|:stable|:falling, delta: float, sparkline: [float]}
  """
  def sapience_trend(did, days \\ 30) do
    case CheckIn.history(did, days) do
      {:ok, snapshots} ->
        indices = snapshots
          |> Enum.reverse()
          |> Enum.map(fn s -> s["sapience_index"] || 0.0 end)

        n = length(indices)
        if n < 3 do
          {:ok, %{trend: :unknown, delta: 0.0, sparkline: indices}}
        else
          first_third  = Enum.take(indices, div(n, 3)) |> avg()
          last_third   = Enum.drop(indices, n - div(n, 3)) |> avg()
          delta        = Float.round(last_third - first_third, 2)

          trend = cond do
            delta > 3.0  -> :rising
            delta < -3.0 -> :falling
            true         -> :stable
          end

          {:ok, %{
            trend:     trend,
            delta:     delta,
            current:   List.last(indices) || 0.0,
            average:   avg(indices),
            sparkline: indices,
          }}
        end

      _ ->
        {:ok, %{trend: :unknown, delta: 0.0, sparkline: []}}
    end
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp parse_filter_states(nil),   do: %{}
  defp parse_filter_states(json) do
    case Jason.decode(json) do
      {:ok, map} -> map
      _          -> %{}
    end
  end

  defp fogged_filters(filter_states) do
    Enum.filter_map(filter_states,
      fn {_, v} -> v["state"] == "fogged" end,
      fn {k, _} -> k end)
  end

  defp clear_filters(filter_states) do
    Enum.filter_map(filter_states,
      fn {_, v} -> v["state"] == "clear" end,
      fn {k, _} -> k end)
  end

  defp snapshot_age_hours(nil), do: 999
  defp snapshot_age_hours(ts) when is_integer(ts) do
    div(System.os_time(:microsecond) - ts, 3_600_000_000)
  end
  defp snapshot_age_hours(_), do: 999

  defp band_from_index(s) when s < 25,  do: :deeply_fogged
  defp band_from_index(s) when s < 50,  do: :fogged
  defp band_from_index(s) when s < 70,  do: :transitioning
  defp band_from_index(s) when s < 85,  do: :mostly_clear
  defp band_from_index(_),               do: :high_coherence

  defp default_perception do
    %{
      sapience_index:     0.0,
      sapience_band:      :unknown,
      filter_states:      %{},
      pb_accumulator:     0.0,
      fogged_filters:     [],
      clear_filters:      [],
      heart_state:        "unknown",
      snapshot_age_hours: 999,
      ready_for_insights: false,
    }
  end

  defp avg([]), do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)
end
