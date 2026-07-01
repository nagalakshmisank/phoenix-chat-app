# lib/checkin/holnn_checkin.ex
#
# HOLNN Check-In Service
#
# The ONLY way labeled training data enters the system.
# Users label their own filter states — the model learns their personal patterns.
#
# Two check-in modes:
#
#   Quick check-in (≤30s):
#     For each filter, tap CLEAR or FOGGED.
#     No explanation required. Builds training data fast.
#
#   Deep check-in (5-10 min):
#     Rate each filter 0–100 with a brief reflection.
#     Higher quality training signal. Unlocks richer analytics.
#
# Check-in cadence:
#   Morning check-in: best signal for Practices, Body, Senses
#   Evening check-in: best signal for Mind, Heart, Ego, Knowledge, Detachment
#   Weekly review: full 7-filter assessment with reflection text
#
# After every check-in:
#   1. Label is stored in companion/core/memories.lance
#   2. HOLNN training is re-triggered if label count milestone reached
#   3. Current sapience snapshot is updated immediately using the label
#   4. Companion channel receives the new snapshot

defmodule PRZMA.HOLNN.CheckIn do
  require Logger

  alias PRZMA.HOLNN.{DataCollector, SapienceComputer, InferenceJob, TrainingJob}
  alias PRZMA.PzDb

  @training_milestones [10, 25, 50, 100, 200, 500]

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  @doc """
  Submit a quick check-in. Each filter is either :clear or :fogged.

  filter_states: %{body: :clear, senses: :fogged, mind: :clear, heart: :clear,
                   ego: :fogged, knowledge: :clear, detachment: :fogged}
  """
  def quick_checkin(did, filter_states) when is_map(filter_states) do
    validated = validate_filter_states(filter_states)

    with {:ok, _sample_id}  <- DataCollector.record_label(did, validated, :quick_checkin),
         {:ok, snapshot}    <- apply_labels_immediately(did, validated),
         :ok                <- maybe_trigger_training(did) do

      broadcast_snapshot(did, snapshot)
      Logger.info("HOLNN quick check-in recorded", did: did,
        clear: count_state(validated, :clear),
        fogged: count_state(validated, :fogged))

      {:ok, %{
        snapshot:     snapshot,
        label_count:  DataCollector.count_labeled(did),
        next_training: next_training_milestone(DataCollector.count_labeled(did)),
      }}
    end
  end

  @doc """
  Submit a deep check-in. Each filter has a 0–100 score and optional reflection.

  filter_assessments: %{
    body:        %{score: 72, reflection: "Felt grounded after morning walk"},
    heart:       %{score: 85, reflection: "Deep conversation with Priya"},
    ...
  }
  """
  def deep_checkin(did, filter_assessments) when is_map(filter_assessments) do
    # Convert 0-100 scores to 0.0-1.0 floats for HOLNN
    filter_states = Enum.map(filter_assessments, fn {filter, assessment} ->
      score = (assessment[:score] || assessment["score"] || 50) / 100.0
      {filter, score}
    end) |> Enum.into(%{})

    # Store reflections as vault entries
    reflections = Enum.filter_map(filter_assessments,
      fn {_, a} -> (a[:reflection] || a["reflection"]) not in [nil, ""] end,
      fn {filter, assessment} ->
        reflection = assessment[:reflection] || assessment["reflection"]
        store_reflection(did, filter, reflection, filter_states[filter])
      end
    )

    with {:ok, _sample_id}  <- DataCollector.record_label(did, filter_states, :deep_checkin),
         {:ok, snapshot}    <- apply_labels_immediately(did, filter_states),
         :ok                <- maybe_trigger_training(did) do

      broadcast_snapshot(did, snapshot)
      Logger.info("HOLNN deep check-in recorded",
        did: did, reflections: length(reflections))

      {:ok, %{
        snapshot:          snapshot,
        reflections_saved: length(reflections),
        label_count:       DataCollector.count_labeled(did),
        next_training:     next_training_milestone(DataCollector.count_labeled(did)),
      }}
    end
  end

  @doc """
  Weekly review — full assessment with narrative reflection.
  Highest quality training signal.
  """
  def weekly_review(did, filter_assessments, narrative \\ nil) do
    result = deep_checkin(did, filter_assessments)

    if narrative && narrative != "" do
      store_weekly_narrative(did, narrative, filter_assessments)
    end

    result
  end

  @doc "Get the current check-in state for a DID — what to show the user."
  def current_state(did) do
    # Read latest sapience snapshot
    latest = case PzDb.query(
      "pzdb://#{did}/companion/core/sapience_snapshots/placeholder",
      filter: "deleted_at IS NULL",
      limit: 1
    ) do
      {:ok, %{"records" => [record | _]}} -> record
      _ -> nil
    end

    label_count   = DataCollector.count_labeled(did)
    next_milestone = next_training_milestone(label_count)

    %{
      label_count:     label_count,
      next_milestone:  next_milestone,
      progress_pct:    training_progress_pct(label_count),
      latest_snapshot: latest,
      suggested_mode:  suggest_checkin_mode(did),
      last_checkin_at: latest && latest["snapshot_at"],
    }
  end

  @doc "Check-in history for a DID — last N snapshots."
  def history(did, limit \\ 30) do
    PzDb.query(
      "pzdb://#{did}/companion/core/sapience_snapshots/placeholder",
      filter: "deleted_at IS NULL",
      limit: limit
    )
    |> case do
        {:ok, %{"records" => records}} ->
          {:ok, Enum.sort_by(records, & &1["snapshot_at"], :desc)}
        err -> err
      end
  end

  @doc "Get prompts for each filter to help the user self-assess."
  def filter_prompts do
    %{
      body: %{
        question:    "How does your body feel right now?",
        clear_sign:  "Energised, comfortable, present in your physical experience",
        fogged_sign: "Fatigued, disconnected from body, pain or discomfort present",
        practices:   ~w(morning_movement body_scan breathing),
      },
      senses: %{
        question:    "Are you aware of your senses, or running on autopilot?",
        clear_sign:  "Noticing tastes, sounds, textures — present to sensory experience",
        fogged_sign: "Numb, overstimulated, or unable to notice what is around you",
        practices:   ~w(mindful_eating sensory_walk silence_practice),
      },
      mind: %{
        question:    "Is your mind clear and focused, or scattered and noisy?",
        clear_sign:  "Able to think clearly, focus without strain, ideas feel connected",
        fogged_sign: "Overthinking, mental noise, difficulty concentrating, decision paralysis",
        practices:   ~w(study_session insight_journaling digital_break),
      },
      heart: %{
        question:    "Are you open and connected, or closed and defended?",
        clear_sign:  "Feeling warmth, compassion, ease in connection with others and yourself",
        fogged_sign: "Closed off, reactive, difficulty feeling, isolated or defended",
        practices:   ~w(heart_coherence_breathing gratitude_practice compassion_meditation),
        gateway_note: "This filter opens the door to all others. When Heart is clear, other filters clear more easily.",
      },
      ego: %{
        question:    "Are you operating from your essence, or from ego's need to prove?",
        clear_sign:  "Acting from service, contribution, authentic self-expression",
        fogged_sign: "Comparing, defending, proving, seeking validation, reactive to criticism",
        practices:   ~w(service_act letting_go_practice self_inquiry),
      },
      knowledge: %{
        question:    "Is your knowing lived and integrated, or merely conceptual?",
        clear_sign:  "Wisdom showing up in how you live, not just what you know",
        fogged_sign: "Knowing much but living little of it; information without transformation",
        practices:   ~w(learning_integration wisdom_reflection teaching_sharing),
      },
      detachment: %{
        question:    "Can you hold what is present without grasping or pushing away?",
        clear_sign:  "At ease with what is, neither clinging nor resisting, peaceful equanimity",
        fogged_sign: "Grasping for control, difficulty accepting uncertainty, reactive to change",
        practices:   ~w(stillness_practice surrender_journaling quiet_moments),
      },
    }
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────────

  defp validate_filter_states(states) do
    filters = ~w(body senses mind heart ego knowledge detachment)a

    Enum.map(filters, fn f ->
      val = states[f] || states[to_string(f)] || :unknown
      normalized = case val do
        :clear          -> 1.0
        :fogged         -> 0.0
        v when is_float(v) and v >= 0.0 and v <= 1.0 -> v
        v when is_integer(v) and v >= 0 and v <= 100  -> v / 100.0
        _               -> 0.5
      end
      {f, normalized}
    end) |> Enum.into(%{})
  end

  # Immediately compute a snapshot from the labels without waiting for inference
  defp apply_labels_immediately(did, filter_states) do
    # Convert float scores to HOLNN filter state format
    holnn_states = Enum.map(filter_states, fn {f, score} ->
      {f, %{
        state: if(score >= 0.5, do: :clear, else: :fogged),
        score: Float.round(score, 4),
        label: if(score >= 0.5, do: "CLEAR", else: "FOGGED"),
      }}
    end) |> Enum.into(%{})

    holnn_result = %{
      source:        :user_label,
      filter_states: holnn_states,
      matrix:        %{},  # matrix not from direct label
      confidence:    1.0,  # user-labeled = highest confidence
    }

    SapienceComputer.compute(did, holnn_result)
  end

  defp maybe_trigger_training(did) do
    count = DataCollector.count_labeled(did)
    if count in @training_milestones do
      Logger.info("HOLNN training milestone reached", did: did, count: count)
      TrainingJob.enqueue(did)
    end
    :ok
  end

  defp broadcast_snapshot(did, snapshot_result) do
    PRZMAWeb.Endpoint.broadcast("companion:#{did}", "holnn:snapshot", %{
      filter_states:  snapshot_result.filter_states,
      sapience_index: snapshot_result.sapience_index,
      sapience_band:  snapshot_result.sapience_band,
      pb_accumulator: snapshot_result.pb_accumulator,
      source:         :user_label,
    })
  end

  defp store_reflection(did, filter, text, score) do
    domain = filter_to_vault_domain(filter)
    label  = if score >= 0.5, do: "CLEAR", else: "FOGGED"
    title  = "#{String.capitalize(to_string(filter))} filter reflection [#{label}]"
    PRZMA.Agents.ToolExecutor.execute(did, "vault:write",
      %{"domain" => domain, "title" => title, "body" => text},
      [%{tool: "vault:write", did: did, expires_at: :infinity, is_active: true}])
  end

  defp store_weekly_narrative(did, narrative, _assessments) do
    title = "Weekly perception review — #{Date.utc_today()}"
    PRZMA.Agents.ToolExecutor.execute(did, "vault:write",
      %{"domain" => "my_thoughts", "title" => title, "body" => narrative},
      [%{tool: "vault:write", did: did, expires_at: :infinity, is_active: true}])
  end

  defp filter_to_vault_domain(:body),       do: "my_health"
  defp filter_to_vault_domain(:senses),     do: "my_day"
  defp filter_to_vault_domain(:mind),       do: "my_thoughts"
  defp filter_to_vault_domain(:heart),      do: "my_people"
  defp filter_to_vault_domain(:ego),        do: "who_i_am"
  defp filter_to_vault_domain(:knowledge),  do: "what_i_learned"
  defp filter_to_vault_domain(:detachment), do: "quiet_moments"
  defp filter_to_vault_domain(_),           do: "my_thoughts"

  defp count_state(states, target_state) do
    Enum.count(states, fn {_, v} ->
      (is_float(v) and ((target_state == :clear and v >= 0.5) or (target_state == :fogged and v < 0.5))) or
      v == target_state
    end)
  end

  defp next_training_milestone(count) do
    Enum.find(@training_milestones, fn m -> m > count end)
  end

  defp training_progress_pct(count) do
    next = next_training_milestone(count)
    prev = Enum.filter(@training_milestones, fn m -> m <= count end) |> List.last() || 0
    if next, do: (count - prev) / (next - prev) * 100, else: 100.0
  end

  defp suggest_checkin_mode(did) do
    hour = DateTime.utc_now().hour
    cond do
      hour in 5..9   -> :morning_quick
      hour in 10..17 -> :midday_quick
      hour in 18..22 -> :evening_deep
      true           -> :quick
    end
  end
end
