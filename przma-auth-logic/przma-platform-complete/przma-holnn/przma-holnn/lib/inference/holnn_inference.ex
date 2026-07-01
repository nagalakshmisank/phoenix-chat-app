# lib/bootstrap/holnn_bootstrap.ex
#
# Heuristic bootstrapper — produces meaningful filter state estimates
# from behavioral patterns with ZERO labeled user data.
#
# Rules derived from the PRZMA 7-filter framework and Vallalar's teachings:
#   Body filter:       cleared by physical practice, disrupted by illness/fatigue
#   Senses filter:     cleared by sensory awareness, disrupted by overstimulation
#   Mind filter:       cleared by study/insight, disrupted by mental overload
#   Heart filter:      cleared by compassion/connection, disrupted by isolation
#   Ego filter:        cleared by service/humility, disrupted by defensiveness
#   Knowledge filter:  cleared by wisdom application, disrupted by intellectualism
#   Detachment filter: cleared by surrender/non-attachment, disrupted by grasping

defmodule PRZMA.HOLNN.Bootstrap do
  require Logger

  alias PRZMA.HOLNN.FeatureExtractor

  @doc """
  Produce bootstrapped filter state estimates from raw behavioral features.
  Returns the same structure as HOLNNInference.run/1.
  No labeled data required — uses rule-based heuristics.
  """
  def estimate(did, opts \\ []) do
    {:ok, features} = FeatureExtractor.extract(did, format: :list, window_days: 30)

    filter_scores = %{
      body:        estimate_body(features),
      senses:      estimate_senses(features),
      mind:        estimate_mind(features),
      heart:       estimate_heart(features),
      ego:         estimate_ego(features),
      knowledge:   estimate_knowledge(features),
      detachment:  estimate_detachment(features),
    }

    # Build filter states from scores
    filter_states = Enum.map(filter_scores, fn {filter, score} ->
      {filter, %{
        state: if(score >= 0.5, do: :clear, else: :fogged),
        score: Float.round(score, 4),
        label: if(score >= 0.5, do: "CLEAR", else: "FOGGED"),
      }}
    end) |> Enum.into(%{})

    # Bootstrap interaction matrix (Heart-weighted identity-like)
    matrix = bootstrap_matrix(filter_scores)

    {:ok, %{
      source:        :heuristic,
      filter_states: filter_states,
      matrix:        matrix,
      confidence:    0.4,  # heuristic = lower confidence than trained model
      features_used: 446,
    }}
  end

  # ── FILTER HEURISTICS ─────────────────────────────────────────────────────
  # Each heuristic uses the relevant feature dimensions.
  # Dimension indices correspond to HOLNNFeatureExtractor group layout.

  # Group 1 starts at dim 0
  # Group 3 (practice adherence) starts at dim 40+42=82, length 30
  # Practice adherence for Body-associated practices: dims 82..88 (streaks)

  defp estimate_body(features) do
    # Body filter: physical practice adherence + energy levels + health activity
    practice_body_streak = dim(features, 82)   # body practice streak
    physical_activity    = dim(features, 22)   # activity event ratio (group 1)
    energy_level         = dim(features, 243)  # energy trend (group 9 approx)

    # Heart gateway influence — if Heart is clear, Body clears more easily
    heart_score = dim(features, 85)  # heart practice streak

    weighted_avg([
      {practice_body_streak, 3},
      {physical_activity,    2},
      {energy_level,         1},
      {heart_score * 0.3,    1},  # gateway influence
    ])
  end

  defp estimate_senses(features) do
    # Senses filter: sensory awareness, calm environment, not overstimulated
    early_morning  = dim(features, 6)    # early event ratio (calmer day start)
    focus_ratio    = dim(features, 16)   # focus block ratio (non-reactive time)
    practice_senses = dim(features, 83)  # senses practice streak

    weighted_avg([
      {practice_senses, 3},
      {early_morning,   1},
      {focus_ratio,     2},
    ])
  end

  defp estimate_mind(features) do
    # Mind filter: study/learning activity, insight generation, not overloaded
    study_ratio        = dim(features, 24)   # study events ratio
    knowledge_quality  = dim(features, 150)  # what_i_learned quality (group 8)
    btb_meetings       = 1.0 - dim(features, 17)  # inverse of back-to-back ratio
    practice_mind      = dim(features, 84)         # mind practice streak

    weighted_avg([
      {practice_mind,      3},
      {study_ratio,        2},
      {knowledge_quality,  2},
      {btb_meetings,       1},
    ])
  end

  defp estimate_heart(features) do
    # Heart (Gateway) filter: connection, compassion, relational health
    # This is the most important filter — it influences all others
    social_engagement  = dim(features, 130 + 0)   # attendee diversity (group 5 start ≈ 145)
    practice_heart     = dim(features, 85)         # heart practice streak
    gratitude_markers  = dim(features, 210)        # group 6 gratitude markers
    vault_my_people    = dim(features, 50)         # My People domain frequency (group 2)

    weighted_avg([
      {practice_heart,    4},   # practice has highest weight for Heart
      {vault_my_people,   2},
      {social_engagement, 2},
      {gratitude_markers, 1},
    ])
  end

  defp estimate_ego(features) do
    # Ego filter: service orientation, humility markers, not self-referential
    # Inverse of certain patterns
    meeting_ratio      = dim(features, 19)   # high meeting ratio → possible ego engagement
    milestone_ratio    = dim(features, 21)   # milestone focus → can be ego-driven
    practice_ego       = dim(features, 86)   # ego practice streak
    service_markers    = dim(features, 370)  # relationship support-giving ratio (group 12)

    # Ego filter is often the hardest to assess — use conservative estimate
    weighted_avg([
      {practice_ego,   4},
      {service_markers, 2},
      {1.0 - meeting_ratio * 0.3,  1},  # high meeting load ≠ fogged ego necessarily
      {0.6,            1},              # conservative prior
    ])
  end

  defp estimate_knowledge(features) do
    # Knowledge filter: wisdom application, not just accumulation
    # Cleared by insight + application, not just information gathering
    insight_density    = dim(features, 290)  # group 8 insight density
    knowledge_quality  = dim(features, 145)  # what_i_learned quality
    practice_knowledge = dim(features, 87)   # knowledge practice streak
    reflection_depth   = dim(features, 320)  # group 11 reflection quality

    weighted_avg([
      {practice_knowledge, 3},
      {insight_density,    3},
      {reflection_depth,   2},
      {knowledge_quality,  1},
    ])
  end

  defp estimate_detachment(features) do
    # Detachment filter: non-attachment, surrender, equanimity
    # Hardest to estimate from behavioral data — most inner
    quiet_moments_freq  = dim(features, 100)  # quiet_moments domain frequency
    practice_detachment = dim(features, 88)   # detachment practice streak
    equanimity_markers  = dim(features, 260)  # group 9 equanimity markers
    reflection_depth    = dim(features, 320)

    # Prior toward FOGGED — Detachment is the last to clear
    weighted_avg([
      {practice_detachment, 4},
      {quiet_moments_freq,  3},
      {equanimity_markers,  2},
      {reflection_depth,    1},
      {0.3,                 1},  # conservative prior — detachment is hard
    ])
  end

  # ── INTERACTION MATRIX BOOTSTRAP ─────────────────────────────────────────

  defp bootstrap_matrix(filter_scores) do
    filters = [:body, :senses, :mind, :heart, :ego, :knowledge, :detachment]

    for {from, i} <- Enum.with_index(filters) do
      row = for {to, j} <- Enum.with_index(filters) do
        influence = if from == to do
          # Self-influence = own clarity score
          filter_scores[from]
        else
          # Heart has elevated influence on all other filters (gateway role)
          base = (filter_scores[from] + filter_scores[to]) / 2.0
          if from == :heart or to == :heart do
            min(base * 1.3, 1.0)
          else
            base
          end
        end
        {to, Float.round(influence, 4)}
      end |> Enum.into(%{})
      {from, row}
    end |> Enum.into(%{})
  end

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp dim(features, idx) when idx < length(features) do
    Enum.at(features, idx, 0.5)
  end
  defp dim(_features, _idx), do: 0.5

  defp weighted_avg(pairs) do
    {sum, weight} = Enum.reduce(pairs, {0.0, 0}, fn {v, w}, {s, tw} ->
      {s + v * w, tw + w}
    end)
    if weight == 0, do: 0.5, else: Float.round(min(max(sum / weight, 0.0), 1.0), 4)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/training/holnn_data_collector.ex
#
# Collects and stores labeled training samples for HOLNN personal training.
# Each sample = {features: 446-dim, labels: {filter_states: 7-dim, matrix: 49-dim}}.

defmodule PRZMA.HOLNN.DataCollector do
  alias PRZMA.PzDb
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  @doc "Record a labeled snapshot from user check-in."
  def record_label(did, filter_state_labels, source \\ :user_checkin) do
    with {:ok, features} <- PRZMA.HOLNN.FeatureExtractor.extract(did, format: :list) do
      # Convert user labels to 7-dim float vector [0=FOGGED, 1=CLEAR]
      filter_vec = PRZMA.HOLNN.Model.filter_names()
        |> Enum.map(fn f ->
            case filter_state_labels[f] || filter_state_labels[String.to_atom(f)] do
              :clear  -> 1.0
              :fogged -> 0.0
              v when is_float(v) -> v
              _       -> 0.5
            end
          end)

      # Bootstrap matrix from labels
      matrix_vec = generate_matrix_labels(filter_vec)

      sample_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      uri       = "pzdb://#{did}/companion/core/memories/holnn_label_#{sample_id}"

      record = %{
        "id"              => "holnn_label_#{sample_id}",
        "did"             => did,
        "memory_type"     => "holnn_training_sample",
        "title"           => "HOLNN training label #{DateTime.utc_now() |> DateTime.to_date()}",
        "body_cas"        => nil,
        "source_uri"      => nil,
        "source_service"  => "holnn_collector",
        "filter_state_json" => Jason.encode!(filter_state_labels),
        "valence"         => Enum.sum(filter_vec) / 7.0 - 0.5,
        "salience"        => 1.0,  # training samples are always high salience
        "embedding"       => List.duplicate(0.0, 768),
        "recalled_count"  => 0,
        # Store features and labels as JSON blobs
        "features_json"   => Jason.encode!(features),
        "filter_vec_json" => Jason.encode!(filter_vec),
        "matrix_vec_json" => Jason.encode!(matrix_vec),
        "source"          => to_string(source),
        "created_at"      => System.os_time(:microsecond),
        "updated_at"      => System.os_time(:microsecond),
      }

      case PzDb.write(uri, record) do
        {:ok, _} ->
          Logger.info("HOLNN training sample recorded",
            did: did, sample_id: sample_id)
          {:ok, sample_id}
        err -> err
      end
    end
  end

  @doc "Count labeled samples available for training."
  def count_labeled(did) do
    case PzDb.query(
      "pzdb://#{did}/companion/core/memories/placeholder",
      filter: "memory_type = 'holnn_training_sample' AND salience = 1.0",
      limit:  1000
    ) do
      {:ok, %{"records" => records}} -> length(records)
      _                              -> 0
    end
  end

  @doc "Load all labeled samples as {features, labels} tuples."
  def load_labeled(did) do
    case PzDb.query(
      "pzdb://#{did}/companion/core/memories/placeholder",
      filter: "memory_type = 'holnn_training_sample'",
      limit:  500
    ) do
      {:ok, %{"records" => records}} ->
        samples = Enum.filter_map(records,
          fn r -> r["features_json"] && r["filter_vec_json"] end,
          fn r ->
            features   = Jason.decode!(r["features_json"])
            filter_vec = Jason.decode!(r["filter_vec_json"])
            matrix_vec = if r["matrix_vec_json"],
              do:   Jason.decode!(r["matrix_vec_json"]),
              else: generate_matrix_labels(filter_vec)

            features_t = Nx.tensor([features], type: :f32)
            labels = %{
              filter_states: filter_vec,
              matrix:        matrix_vec,
            }
            {features_t, labels}
          end)
        {:ok, samples}
      {:error, msg} ->
        {:error, msg}
    end
  end

  # Bootstrap a 49-dim matrix from 7 filter labels
  defp generate_matrix_labels(filter_vec) do
    n = length(filter_vec)
    for i <- 0..(n-1), j <- 0..(n-1) do
      fi = Enum.at(filter_vec, i, 0.5)
      fj = Enum.at(filter_vec, j, 0.5)
      if i == j, do: fi, else: (fi + fj) / 2.0
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/inference/holnn_inference.ex
#
# HOLNN inference — runs a trained (or bootstrapped) model and produces
# filter states, interaction matrix, and Sapience Index.

defmodule PRZMA.HOLNN.Inference do
  require Logger

  alias PRZMA.HOLNN.{Model, FeatureExtractor, Bootstrap, SapienceComputer}
  alias PRZMA.PzDb

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  @doc """
  Run the full HOLNN inference pipeline for a DID.

  Returns {:ok, HolnnResult} where HolnnResult contains:
    filter_states:   %{body: %{state: :clear|:fogged, score: float, label: string}, ...}
    matrix:          7×7 map of filter→filter influence scores
    sapience_index:  S = 40Λ + 30(1-Γ) + 15Φ₄ + 15P
    sapience_detail: %{lambda, gamma, phi4, practice_score}
    source:          :trained | :heuristic
    confidence:      0.0..1.0
  """
  def run(did, opts \\ []) do
    with {:ok, features}        <- FeatureExtractor.extract(did, window_days: opts[:window_days] || 30),
         {:ok, holnn_result}    <- infer(did, features),
         {:ok, sapience_result} <- SapienceComputer.compute(did, holnn_result, opts) do

      result = Map.merge(holnn_result, sapience_result)

      # Persist snapshot to Lance
      persist_snapshot(did, result)

      {:ok, result}
    end
  end

  # ── INFERENCE ROUTING ─────────────────────────────────────────────────────

  defp infer(did, features) do
    # Try trained personal model first; fall back to heuristic
    case load_trained_model(did) do
      {:ok, {model, params}} ->
        run_trained_model(model, params, features)
      {:error, _} ->
        Logger.debug("HOLNN: no trained model — using heuristic bootstrap", did: did)
        {:ok, features_list} = FeatureExtractor.extract(did, format: :list)
        # Bootstrap uses string-based DID path
        Bootstrap.estimate(did)
    end
  end

  defp run_trained_model(model, params, features) do
    predictions = Axon.predict(model, params, features, mode: :inference)

    filter_states = Model.to_filter_states(predictions.filter_states)
    matrix        = Model.to_interaction_matrix(predictions.matrix)

    {:ok, %{
      source:        :trained,
      filter_states: filter_states,
      matrix:        matrix,
      confidence:    0.85,
    }}
  end

  defp load_trained_model(did) do
    # Check if a trained model exists in CAS
    case PzDb.query(
      "pzdb://#{did}/ai/core/model_registry/placeholder",
      filter: "model_type = 'classification' AND is_active = true AND model_name LIKE 'holnn_%'",
      limit:  1
    ) do
      {:ok, %{"records" => [record | _]}} when record["model_cas"] != nil ->
        cas_uri = record["model_cas"]
        case PRZMA.Platform.CAS.get(did, cas_uri) do
          {:ok, binary} ->
            params = :erlang.binary_to_term(binary, [:safe])
            model  = Model.build_inference()
            {:ok, {model, params}}
          err -> err
        end
      _ ->
        {:error, :no_trained_model}
    end
  end

  defp persist_snapshot(did, result) do
    snapshot_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    uri = "pzdb://#{did}/companion/core/sapience_snapshots/#{snapshot_id}"

    filter_states_json = Jason.encode!(
      Enum.map(result.filter_states, fn {f, s} ->
        {to_string(f), %{state: to_string(s.state), score: s.score}}
      end) |> Enum.into(%{})
    )

    record = %{
      "id"                 => snapshot_id,
      "did"                => did,
      "lambda"             => get_in(result, [:sapience_detail, :lambda]) || 0.0,
      "gamma"              => get_in(result, [:sapience_detail, :gamma])  || 0.5,
      "phi4"               => get_in(result, [:sapience_detail, :phi4])   || 0.0,
      "practice_score"     => get_in(result, [:sapience_detail, :practice_score]) || 0.0,
      "sapience_index"     => result[:sapience_index]    || 0.0,
      "filter_states_json" => filter_states_json,
      "holnn_matrix_json"  => Jason.encode!(result[:matrix] || %{}),
      "pb_accumulator"     => result[:pb_accumulator]    || 0.0,
      "cri_modulation"     => result[:cri_modulation]    || 1.0,
      "sas_score"          => result[:sas_score]         || 0.0,
      "snapshot_at"        => System.os_time(:microsecond),
      "period_days"        => 30,
    }

    PzDb.write(uri, record, encrypt: false)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/inference/sapience_computer.ex
#
# Computes the Sapience Index: S = 40Λ + 30(1-Γ) + 15Φ₄ + 15P
#
#   Λ (Lambda)  = Coherence.     How aligned and coherent the filter states are.
#                                High = all filters moving toward CLEAR together.
#   Γ (Gamma)   = Distortion.    Variance/conflict between filter states.
#                                High = some filters CLEAR, others deeply FOGGED.
#   Φ₄ (Phi4)  = Heart clarity. The Gateway filter — direct from HOLNN output.
#   P           = Practice.      Adherence to daily practices from calendar data.
#
# S range: 0..100
#   0–25:  Very FOGGED — significant perceptual distortion
#   25–50: FOGGED — some clarity emerging
#   50–70: Transitioning — more CLEAR than FOGGED
#   70–85: Mostly CLEAR — coherent perception
#   85–100: High coherence — Light clarity

defmodule PRZMA.HOLNN.SapienceComputer do
  alias PRZMA.Calendar.Intelligence.Analytics
  require Logger

  @doc """
  Compute the Sapience Index from HOLNN output and calendar data.
  S = 40Λ + 30(1-Γ) + 15Φ₄ + 15P
  """
  def compute(did, holnn_result, opts \\ []) do
    filter_states = holnn_result.filter_states

    # Extract raw clarity scores for all 7 filters
    scores = PRZMA.HOLNN.Model.filter_names()
      |> Enum.map(fn f -> get_in(filter_states, [String.to_atom(f), :score]) || 0.5 end)

    # Λ — coherence: mean clarity, weighted toward Heart (gateway)
    heart_score = get_in(filter_states, [:heart, :score]) || 0.5
    mean_score  = Enum.sum(scores) / 7.0
    lambda      = (mean_score * 0.7 + heart_score * 0.3)  # Heart-weighted mean

    # Γ — distortion: variance among filter scores
    # High variance = some CLEAR, some FOGGED = perceptual conflict
    variance = Statistics.variance(scores)  # or compute manually
    gamma    = Float.round(:math.sqrt(variance), 4)  # std dev as distortion proxy

    # Φ₄ — Heart Filter clarity (direct)
    phi4 = heart_score

    # P — practice adherence from calendar analytics
    practice_score = fetch_practice_score(did)

    # S = 40Λ + 30(1-Γ) + 15Φ₄ + 15P
    s = 40 * lambda + 30 * (1.0 - gamma) + 15 * phi4 + 15 * practice_score
    s = Float.round(min(max(s, 0.0), 100.0), 2)

    # Pb accumulator (+0.008/+0.012/+0.005 per filter cleared, 2% weekly decay)
    pb = compute_pb(did, filter_states)

    {:ok, %{
      sapience_index: s,
      sapience_band:  band(s),
      sapience_detail: %{
        lambda:         Float.round(lambda,         4),
        gamma:          Float.round(gamma,          4),
        phi4:           Float.round(phi4,           4),
        practice_score: Float.round(practice_score, 4),
      },
      pb_accumulator:  pb,
      cri_modulation:  1.0,  # Phase final: Bronfenbrenner C1 SAS computation
      sas_score:       0.0,
    }}
  end

  defp fetch_practice_score(did) do
    # Use calendar practice adherence over 30 days
    {start_us, now_us} = Analytics.last_n_days(30)
    case PRZMA.Calendar.NIF.practice_adherence(
          Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults"),
          did, "practice", start_us, now_us) do
      {:ok, json} ->
        data = Jason.decode!(json)
        min((data["adherence_pct"] || 0.0) / 100.0, 1.0)
      _ ->
        0.5
    end
  end

  defp compute_pb(did, filter_states) do
    # Pb accumulates when filters clear:
    #   +0.008 per Body/Senses/Mind filter clearing event
    #   +0.012 per Heart/Ego filter clearing event
    #   +0.005 per Knowledge/Detachment filter clearing event
    # Then decays 2% per week
    #
    # Phase final: compare current states to previous snapshot to detect transitions
    filter_rates = %{
      body: 0.008, senses: 0.008, mind: 0.008,
      heart: 0.012, ego: 0.012,
      knowledge: 0.005, detachment: 0.005,
    }
    base_pb = Enum.reduce(filter_rates, 0.0, fn {filter, rate}, acc ->
      score = get_in(filter_states, [filter, :score]) || 0.0
      acc + score * rate
    end)
    Float.round(base_pb, 6)
  end

  defp band(s) when s < 25,  do: :deeply_fogged
  defp band(s) when s < 50,  do: :fogged
  defp band(s) when s < 70,  do: :transitioning
  defp band(s) when s < 85,  do: :mostly_clear
  defp band(_),               do: :high_coherence

  # Manual variance computation (avoid Statistics dep if not available)
  defmodule Statistics do
    def variance([]), do: 0.0
    def variance(list) do
      n    = length(list)
      mean = Enum.sum(list) / n
      Enum.sum(Enum.map(list, fn x -> (x - mean) * (x - mean) end)) / n
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/oban/holnn_jobs.ex
#
# Oban background jobs for HOLNN training and inference.

defmodule PRZMA.HOLNN.InferenceJob do
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did}}) do
    case PRZMA.HOLNN.Inference.run(did) do
      {:ok, result} ->
        PRZMA.HOLNN.BroadcastResult.broadcast(did, result)
        :ok
      {:error, reason} ->
        {:error, reason}
    end
  end

  def enqueue(did, schedule_in \\ 0) do
    %{did: did}
    |> new(schedule_in: schedule_in)
    |> Oban.insert()
  end
end

defmodule PRZMA.HOLNN.TrainingJob do
  use Oban.Worker, queue: :maintenance, max_attempts: 2

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did}}) do
    require Logger
    Logger.info("HOLNN training job starting", did: did)
    case PRZMA.HOLNN.Trainer.train(did) do
      {:ok, result} ->
        Logger.info("HOLNN training complete", did: did, result: inspect(result))
        # Immediately run inference with new model
        PRZMA.HOLNN.InferenceJob.enqueue(did)
        :ok
      {:error, reason} ->
        {:error, reason}
    end
  end

  def enqueue(did) do
    %{did: did}
    |> new(schedule_in: 60)  # 1 minute delay
    |> Oban.insert()
  end
end

defmodule PRZMA.HOLNN.BroadcastResult do
  @doc "Broadcast HOLNN result to the companion channel."
  def broadcast(did, result) do
    PRZMAWeb.Endpoint.broadcast("calendar:personal:#{did}", "holnn:result", %{
      filter_states:  result.filter_states,
      sapience_index: result.sapience_index,
      sapience_band:  result.sapience_band,
      source:         result.source,
      snapshot_at:    System.os_time(:microsecond),
    })
  end
end
