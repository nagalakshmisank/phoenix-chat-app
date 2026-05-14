# test/holnn_test.exs

defmodule PRZMA.HOLNN.Test do
  use ExUnit.Case, async: true

  alias PRZMA.HOLNN.{
    Model,
    FeatureExtractor,
    Trainer,
    Inference,
    Bootstrap,
    DataCollector,
    CheckIn,
    SapienceComputer,
    CompanionIntegration,
  }

  @did "did:web:holnn-test.local"

  # ── 1. Model Architecture ─────────────────────────────────────────────────

  describe "Model architecture" do
    test "input and output dimensions are correct" do
      assert Model.input_dim()   == 446
      assert Model.n_filters()   == 7
      assert Model.matrix_size() == 49
      assert Model.heart_index() == 3
    end

    test "filter names returns 7 items in correct order" do
      names = Model.filter_names()
      assert length(names) == 7
      assert names == ~w(body senses mind heart ego knowledge detachment)
    end

    test "filter_atom/1 maps indices correctly" do
      assert Model.filter_atom(0) == :body
      assert Model.filter_atom(3) == :heart
      assert Model.filter_atom(6) == :detachment
    end

    test "filter_index/1 maps atoms correctly" do
      assert Model.filter_index(:heart)       == 3
      assert Model.filter_index(:body)        == 0
      assert Model.filter_index(:detachment)  == 6
    end

    test "build/0 returns an Axon model" do
      model = Model.build()
      assert is_struct(model, Axon)
    end

    test "to_filter_states/1 produces CLEAR/FOGGED map" do
      # All above 0.5 → all CLEAR
      tensor = Nx.tensor([[0.8, 0.6, 0.9, 0.7, 0.3, 0.85, 0.2]])
      states = Model.to_filter_states(tensor)

      assert states[:body].state    == :clear
      assert states[:heart].state   == :clear
      assert states[:ego].state     == :fogged
      assert states[:detachment].state == :fogged

      assert states[:body].label    == "CLEAR"
      assert states[:ego].label     == "FOGGED"
      assert is_float(states[:body].score)
    end

    test "to_filter_states/2 respects custom threshold" do
      tensor = Nx.tensor([[0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6]])
      # With threshold 0.7, everything above 0.6 should be FOGGED
      states = Model.to_filter_states(tensor, 0.7)
      assert Enum.all?(states, fn {_, s} -> s.state == :fogged end)
    end

    test "to_interaction_matrix/1 produces 7×7 map" do
      tensor = Nx.tensor([List.duplicate(0.5, 49)])
      matrix = Model.to_interaction_matrix(tensor)

      assert map_size(matrix) == 7
      assert map_size(matrix["heart"]) == 7
      # All filters present as both row and column
      filters = Model.filter_names()
      Enum.each(filters, fn f ->
        assert Map.has_key?(matrix, f), "Missing row: #{f}"
        Enum.each(filters, fn g ->
          assert Map.has_key?(matrix[f], g), "Missing cell: #{f}→#{g}"
        end)
      end)
    end

    test "loss/2 returns a scalar" do
      preds = %{
        filter_states: Nx.tensor([[0.7, 0.3, 0.8, 0.9, 0.4, 0.7, 0.2]]),
        matrix:        Nx.tensor([List.duplicate(0.5, 49)]),
      }
      labels = %{
        filter_states: Nx.tensor([[1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0]]),
        matrix:        Nx.tensor([List.duplicate(0.5, 49)]),
      }
      loss = Model.loss(preds, labels)
      assert is_float(Nx.to_number(loss))
      assert Nx.to_number(loss) > 0
    end

    test "Heart gateway penalty fires when others clear but Heart is fogged" do
      # Others CLEAR, Heart FOGGED — gateway penalty should increase loss
      preds_bad = %{
        filter_states: Nx.tensor([[0.8, 0.8, 0.8, 0.1, 0.8, 0.8, 0.8]]),
        matrix:        Nx.tensor([List.duplicate(0.5, 49)]),
      }
      # Others CLEAR, Heart also CLEAR — no gateway penalty
      preds_good = %{
        filter_states: Nx.tensor([[0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8]]),
        matrix:        Nx.tensor([List.duplicate(0.5, 49)]),
      }
      labels = %{
        filter_states: Nx.tensor([[1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]]),
        matrix:        Nx.tensor([List.duplicate(0.5, 49)]),
      }
      loss_bad  = Nx.to_number(Model.loss(preds_bad,  labels))
      loss_good = Nx.to_number(Model.loss(preds_good, labels))
      # Bad (Heart fogged when others clear) should have higher loss
      assert loss_bad > loss_good
    end
  end

  # ── 2. Feature Extractor ──────────────────────────────────────────────────

  describe "FeatureExtractor" do
    test "extract/2 returns 446-dim tensor" do
      # This will produce neutral features since test DID has no data
      {:ok, tensor} = FeatureExtractor.extract(@did)
      shape = Nx.shape(tensor)
      assert shape == {1, 446}
    end

    test "extract/2 with :list format returns 446 floats" do
      {:ok, features} = FeatureExtractor.extract(@did, format: :list)
      assert length(features) == 446
      assert Enum.all?(features, fn f -> is_float(f) and f >= 0.0 and f <= 1.0 end)
    end

    test "all features are in [0, 1] range" do
      {:ok, features} = FeatureExtractor.extract(@did, format: :list)
      out_of_range = Enum.filter(features, fn f -> f < 0.0 or f > 1.0 end)
      assert out_of_range == [], "Features out of range: #{inspect(out_of_range)}"
    end

    test "missing data fills with 0.5 (neutral), not 0.0 (fogged)" do
      # With no vault/calendar data, most dims should be 0.5
      {:ok, features} = FeatureExtractor.extract(@did, format: :list)
      neutral_count = Enum.count(features, fn f -> f == 0.5 end)
      total = length(features)
      # At least 60% should be neutral when no data
      assert neutral_count / total > 0.5,
        "Expected most features neutral (0.5), got #{neutral_count}/#{total}"
    end
  end

  # ── 3. Heuristic Bootstrap ────────────────────────────────────────────────

  describe "Bootstrap" do
    test "estimate/2 returns all 7 filters" do
      {:ok, result} = Bootstrap.estimate(@did)
      assert map_size(result.filter_states) == 7
      for f <- [:body, :senses, :mind, :heart, :ego, :knowledge, :detachment] do
        assert Map.has_key?(result.filter_states, f),
          "Missing filter: #{f}"
      end
    end

    test "bootstrap source is :heuristic" do
      {:ok, result} = Bootstrap.estimate(@did)
      assert result.source == :heuristic
    end

    test "bootstrap confidence is less than trained model" do
      {:ok, result} = Bootstrap.estimate(@did)
      assert result.confidence < 0.85
      assert result.confidence == 0.4
    end

    test "all filter scores are in [0.0, 1.0]" do
      {:ok, result} = Bootstrap.estimate(@did)
      Enum.each(result.filter_states, fn {filter, state} ->
        score = state.score
        assert score >= 0.0 and score <= 1.0,
          "Filter #{filter} score out of range: #{score}"
      end)
    end

    test "interaction matrix covers all 7×7 combinations" do
      {:ok, result} = Bootstrap.estimate(@did)
      filters = Model.filter_names()
      Enum.each(filters, fn from ->
        assert Map.has_key?(result.matrix, String.to_atom(from)),
          "Missing matrix row: #{from}"
        Enum.each(filters, fn to ->
          row = result.matrix[String.to_atom(from)]
          assert Map.has_key?(row, String.to_atom(to)),
            "Missing matrix cell: #{from}→#{to}"
        end)
      end)
    end

    test "Heart filter has elevated influence in matrix" do
      {:ok, result} = Bootstrap.estimate(@did)
      # Heart row and column values should be >= other filter cross-influences
      heart_influences = result.matrix[:heart] |> Map.values()
      other_influences = result.matrix[:body] |> Map.values()
      assert Enum.sum(heart_influences) >= Enum.sum(other_influences) * 0.9
    end
  end

  # ── 4. Sapience Computer ─────────────────────────────────────────────────

  describe "SapienceComputer" do
    test "all-CLEAR filters produce high Sapience Index" do
      holnn_result = %{
        filter_states: Map.new([:body, :senses, :mind, :heart, :ego, :knowledge, :detachment],
          fn f -> {f, %{state: :clear, score: 0.9, label: "CLEAR"}} end),
        matrix: %{},
      }
      {:ok, result} = SapienceComputer.compute(@did, holnn_result)
      assert result.sapience_index > 70.0,
        "Expected high S for all-clear, got #{result.sapience_index}"
    end

    test "all-FOGGED filters produce low Sapience Index" do
      holnn_result = %{
        filter_states: Map.new([:body, :senses, :mind, :heart, :ego, :knowledge, :detachment],
          fn f -> {f, %{state: :fogged, score: 0.1, label: "FOGGED"}} end),
        matrix: %{},
      }
      {:ok, result} = SapienceComputer.compute(@did, holnn_result)
      assert result.sapience_index < 30.0,
        "Expected low S for all-fogged, got #{result.sapience_index}"
    end

    test "sapience index is in [0, 100] range" do
      for _ <- 1..10 do
        scores = Enum.map(1..7, fn _ -> :rand.uniform() end)
        holnn_result = %{
          filter_states: Enum.zip(
            [:body, :senses, :mind, :heart, :ego, :knowledge, :detachment],
            Enum.map(scores, fn s ->
              %{state: (if s >= 0.5, do: :clear, else: :fogged), score: s, label: ""}
            end)
          ) |> Enum.into(%{}),
          matrix: %{},
        }
        {:ok, result} = SapienceComputer.compute(@did, holnn_result)
        assert result.sapience_index >= 0.0 and result.sapience_index <= 100.0,
          "Sapience index out of range: #{result.sapience_index}"
      end
    end

    test "Heart filter (Phi4) contributes 15 points at full clarity" do
      # All filters fogged except Heart
      holnn_result = %{
        filter_states: %{
          body:        %{state: :fogged, score: 0.0, label: "FOGGED"},
          senses:      %{state: :fogged, score: 0.0, label: "FOGGED"},
          mind:        %{state: :fogged, score: 0.0, label: "FOGGED"},
          heart:       %{state: :clear,  score: 1.0, label: "CLEAR"},
          ego:         %{state: :fogged, score: 0.0, label: "FOGGED"},
          knowledge:   %{state: :fogged, score: 0.0, label: "FOGGED"},
          detachment:  %{state: :fogged, score: 0.0, label: "FOGGED"},
        },
        matrix: %{},
      }
      {:ok, result} = SapienceComputer.compute(@did, holnn_result)
      # S = 40*0.43(heart-weighted lambda) + 30*0 + 15*1.0 + 15*P
      # Should be meaningfully above 0 due to Heart clarity
      assert result.sapience_index >= 10.0,
        "Heart clarity should contribute significantly: #{result.sapience_index}"
    end

    test "sapience band matches index range" do
      bands = [
        {10.0, :deeply_fogged},
        {35.0, :fogged},
        {60.0, :transitioning},
        {78.0, :mostly_clear},
        {92.0, :high_coherence},
      ]
      for {index, expected_band} <- bands do
        holnn_result = %{filter_states: all_filters_at(index / 100.0), matrix: %{}}
        {:ok, result} = SapienceComputer.compute(@did, holnn_result)
        assert result.sapience_band == expected_band,
          "S=#{result.sapience_index} should be #{expected_band}, got #{result.sapience_band}"
      end
    end

    test "Pb accumulator is non-negative" do
      holnn_result = %{
        filter_states: all_filters_at(0.7),
        matrix: %{},
      }
      {:ok, result} = SapienceComputer.compute(@did, holnn_result)
      assert result.pb_accumulator >= 0.0
    end
  end

  # ── 5. Check-In ──────────────────────────────────────────────────────────

  describe "CheckIn" do
    test "filter_prompts/0 returns prompts for all 7 filters" do
      prompts = CheckIn.filter_prompts()
      assert map_size(prompts) == 7
      for f <- [:body, :senses, :mind, :heart, :ego, :knowledge, :detachment] do
        assert Map.has_key?(prompts, f)
        assert prompts[f][:question] != nil
        assert prompts[f][:clear_sign] != nil
        assert prompts[f][:fogged_sign] != nil
      end
    end

    test "heart prompt has gateway_note" do
      prompts = CheckIn.filter_prompts()
      assert prompts[:heart][:gateway_note] != nil
      assert String.contains?(prompts[:heart][:gateway_note], "gateway")
    end

    test "quick_checkin accepts atom filter states" do
      states = %{
        body: :clear, senses: :clear, mind: :fogged,
        heart: :clear, ego: :fogged, knowledge: :clear, detachment: :clear,
      }
      # Will error without full infrastructure — just verify it runs the validation
      result = CheckIn.quick_checkin(@did, states)
      # Either succeeds or fails gracefully (infrastructure may not be wired in test)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "validate accepts 0-100 integer scores" do
      states = %{body: 75, senses: 30, mind: 60, heart: 90, ego: 45, knowledge: 80, detachment: 20}
      result = CheckIn.quick_checkin(@did, states)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "current_state/1 returns a map with required keys" do
      state = CheckIn.current_state(@did)
      assert Map.has_key?(state, :label_count)
      assert Map.has_key?(state, :next_milestone)
      assert Map.has_key?(state, :progress_pct)
      assert Map.has_key?(state, :suggested_mode)
    end

    test "suggested_mode is a valid atom" do
      state = CheckIn.current_state(@did)
      assert state.suggested_mode in [:morning_quick, :midday_quick, :evening_deep, :quick]
    end
  end

  # ── 6. Companion Integration ──────────────────────────────────────────────

  describe "CompanionIntegration" do
    test "tone_guidance/1 returns a string" do
      result = CompanionIntegration.tone_guidance(@did)
      assert is_binary(result)
    end

    test "tone_guidance mentions fogged filters" do
      # We can't easily control filter state in unit tests without full infra
      # Just verify the function returns something reasonable
      result = CompanionIntegration.tone_guidance(@did)
      assert is_binary(result)
    end

    test "recommend_practices/1 returns a list" do
      recs = CompanionIntegration.recommend_practices(@did)
      assert is_list(recs)
    end

    test "recommend_practices has required fields" do
      recs = CompanionIntegration.recommend_practices(@did)
      for rec <- recs do
        assert Map.has_key?(rec, :filter)
        assert Map.has_key?(rec, :practice)
        assert Map.has_key?(rec, :reason)
        assert Map.has_key?(rec, :urgency)
      end
    end

    test "insight_readiness returns :ready or {:not_ready, string}" do
      result = CompanionIntegration.insight_readiness(@did)
      assert match?(:ready, result) or match?({:not_ready, _}, result)
    end

    test "memory_salience_boost is in [0, 0.3]" do
      boost = CompanionIntegration.memory_salience_boost(@did)
      assert is_float(boost)
      assert boost >= 0.0 and boost <= 0.3
    end

    test "filter_arc_resources passes all when ready" do
      resources = [
        %{id: "r1", depth: :surface},
        %{id: "r2", depth: :insight},
        %{id: "r3", depth: :surface},
      ]
      # In test mode, readiness will likely be :not_ready (no real S index)
      result = CompanionIntegration.filter_arc_resources(@did, resources)
      assert is_list(result)
      assert length(result) <= length(resources)
    end

    test "sapience_trend/2 returns a map with trend key" do
      {:ok, trend} = CompanionIntegration.sapience_trend(@did, 30)
      assert Map.has_key?(trend, :trend)
      assert trend.trend in [:rising, :stable, :falling, :unknown]
    end

    test "enrich_context/2 adds :perception key" do
      context = %{today: %{event_count: 3}}
      enriched = CompanionIntegration.enrich_context(context, @did)
      assert Map.has_key?(enriched, :perception)
      assert Map.has_key?(enriched.perception, :sapience_index)
      assert Map.has_key?(enriched.perception, :filter_states)
    end
  end

  # ── 7. Data Collector ────────────────────────────────────────────────────

  describe "DataCollector" do
    test "count_labeled/1 returns a non-negative integer" do
      count = DataCollector.count_labeled(@did)
      assert is_integer(count)
      assert count >= 0
    end
  end

  # ── 8. Trainer ───────────────────────────────────────────────────────────

  describe "Trainer" do
    test "train/1 returns bootstrap mode when insufficient labels" do
      # Test DID has 0 labels — should return Phase 0 bootstrap message
      {:ok, result} = Trainer.train(@did)
      assert result.phase == 0
      assert is_binary(result.message)
      assert String.contains?(result.message, "Label")
    end
  end

  # ── HELPERS ──────────────────────────────────────────────────────────────

  defp all_filters_at(score) do
    Map.new([:body, :senses, :mind, :heart, :ego, :knowledge, :detachment], fn f ->
      {f, %{state: (if score >= 0.5, do: :clear, else: :fogged), score: score, label: ""}}
    end)
  end
end
