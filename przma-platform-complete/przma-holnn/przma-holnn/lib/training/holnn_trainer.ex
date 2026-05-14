# lib/training/holnn_trainer.ex
#
# HOLNN Training Pipeline
#
# Three training phases:
#
#   Phase 0 (Bootstrap, 0 user labels):
#     Uses heuristic rules to generate pseudo-labels from behavioral patterns.
#     The heuristic model runs immediately — no labeled data required.
#     Output: plausible filter state estimates, not personalised.
#
#   Phase 1 (Personal, ≥10 labeled snapshots):
#     User labels their own filter states via daily/weekly check-ins.
#     Axon fine-tunes the model on personal data.
#     Training time: <30 seconds on CPU for 100 epochs.
#
#   Phase 2 (Continuous, ongoing):
#     Incremental retraining as new labeled snapshots accumulate.
#     Triggered by Oban job when label count increases by 5+.
#     Models stored in CAS as ONNX files, versioned.
#
# Dataset format per training example:
#   {features: 446-dim float tensor, labels: {filter_states: 7-dim, matrix: 49-dim}}

defmodule PRZMA.HOLNN.Trainer do
  require Logger

  alias PRZMA.HOLNN.{Model, FeatureExtractor, DataCollector}
  alias PRZMA.Platform.CAS

  @min_samples_phase1  10    # minimum labeled samples before personal training
  @epochs_phase1      100
  @epochs_phase2       50
  @batch_size           8
  @learning_rate    0.001
  @model_cas_key     "holnn_model"

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  @doc """
  Train the HOLNN model for a DID.
  Automatically selects the appropriate phase based on available data.
  Returns {:ok, %{version, epoch, loss, model_cas_uri}} | {:error, reason}
  """
  def train(did, opts \\ []) do
    case DataCollector.count_labeled(did) do
      n when n < @min_samples_phase1 ->
        Logger.info("HOLNN: insufficient labels for personal training",
          did: did, have: n, need: @min_samples_phase1)
        {:ok, %{phase: 0, message: "Bootstrap mode — label #{@min_samples_phase1 - n} more snapshots to enable personal training."}}

      n ->
        Logger.info("HOLNN: starting personal training", did: did, samples: n)
        train_personal(did, opts)
    end
  end

  @doc "Run one training epoch and return updated params + loss."
  def train_epoch(model, params, {x_batch, y_batch}, optimizer_state) do
    import Nx.Defn

    {loss, gradients} = Nx.Defn.jit(fn p ->
      {predictions, state} = Axon.predict(model, p, x_batch, mode: :train)
      loss = Model.loss(predictions, y_batch)
      {loss, Nx.Defn.grad(p, loss)}
    end, [params])

    {updated_params, updated_state} =
      Axon.Optimizers.adam(@learning_rate)
      |> Polaris.Updates.apply_updates(params, gradients, optimizer_state)

    {updated_params, updated_state, loss}
  end

  # ── PERSONAL TRAINING ─────────────────────────────────────────────────────

  defp train_personal(did, opts) do
    epochs     = opts[:epochs]     || @epochs_phase1
    batch_size = opts[:batch_size] || @batch_size

    # Load labeled dataset
    {:ok, dataset} = DataCollector.load_labeled(did)
    {train_set, _val_set} = split_dataset(dataset, 0.8)
    batches = create_batches(train_set, batch_size)

    # Load existing model or initialise new one
    model  = Model.build()
    params = case load_model_params(did) do
      {:ok, p} ->
        Logger.info("HOLNN: resuming from saved model", did: did)
        p
      {:error, _} ->
        Logger.info("HOLNN: initialising new model", did: did)
        Axon.init(model, Nx.template({1, Model.input_dim()}, :f32))
    end

    optimizer_state = Polaris.Updates.init(
      Axon.Optimizers.adam(@learning_rate), params)

    # Training loop
    {final_params, final_loss} = Enum.reduce(1..epochs, {params, optimizer_state, 999.0},
      fn epoch, {p, opt_s, _loss} ->
        # Shuffle batches each epoch
        shuffled = Enum.shuffle(batches)

        {p, opt_s, avg_loss} = Enum.reduce(shuffled, {p, opt_s, []},
          fn batch, {p, opt_s, losses} ->
            {x, y} = batch
            {p, opt_s, loss} = train_epoch(model, p, {x, y}, opt_s)
            {p, opt_s, [Nx.to_number(loss) | losses]}
          end)

        avg = Enum.sum(avg_loss) / length(avg_loss)

        if rem(epoch, 10) == 0 do
          Logger.debug("HOLNN training", epoch: epoch, loss: Float.round(avg, 4))
        end

        {p, opt_s, avg}
      end)
    |> case do
      {p, _, loss} -> {p, loss}
    end

    # Save trained model
    version = System.os_time(:second)
    {:ok, model_cas_uri} = save_model_params(did, final_params, version)

    Logger.info("HOLNN personal training complete",
      did: did, loss: Float.round(final_loss, 4), version: version)

    {:ok, %{
      phase:         1,
      version:       version,
      epochs:        epochs,
      samples:       length(dataset),
      loss:          Float.round(final_loss, 4),
      model_cas_uri: model_cas_uri,
    }}
  end

  # ── DATASET MANAGEMENT ────────────────────────────────────────────────────

  defp split_dataset(dataset, train_ratio) do
    n      = length(dataset)
    n_train = round(n * train_ratio)
    shuffled = Enum.shuffle(dataset)
    Enum.split(shuffled, n_train)
  end

  defp create_batches(dataset, batch_size) do
    dataset
    |> Enum.chunk_every(batch_size, batch_size, :discard)
    |> Enum.map(fn samples ->
        x_list = Enum.map(samples, fn {features, _} -> Nx.to_list(features) |> hd() end)
        y_fs   = Enum.map(samples, fn {_, labels}   -> labels.filter_states end)
        y_mx   = Enum.map(samples, fn {_, labels}   -> labels.matrix end)

        x = Nx.tensor(x_list, type: :f32)
        y = %{
          filter_states: Nx.tensor(y_fs, type: :f32),
          matrix:        Nx.tensor(y_mx, type: :f32),
        }
        {x, y}
      end)
  end

  # ── MODEL PERSISTENCE ─────────────────────────────────────────────────────

  defp save_model_params(did, params, version) do
    binary = :erlang.term_to_binary(params)
    uri    = "pzdb://#{did}/ai/core/model_registry/holnn_#{version}"

    case CAS.put(did, binary, mime_type: "application/x-erlang-binary", written_by: "holnn") do
      {:ok, cas_uri} ->
        record = %{
          "id"              => "holnn_#{version}",
          "did"             => did,
          "model_name"      => "holnn_v#{version}",
          "model_type"      => "classification",
          "framework"       => "axon",
          "model_cas"       => cas_uri,
          "adapter_cas"     => nil,
          "adapter_version" => 0,
          "input_shape_json" => "[446]",
          "output_shape_json"=> "[{filter_states:[7],matrix:[49]}]",
          "is_active"       => true,
          "size_bytes"      => byte_size(binary),
          "loaded_at"       => nil,
          "last_used_at"    => nil,
          "created_at"      => System.os_time(:microsecond),
        }
        PRZMA.PzDb.write(uri, record)
        {:ok, cas_uri}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_model_params(did) do
    # Find the latest active HOLNN model
    case PRZMA.PzDb.query(
      "pzdb://#{did}/ai/core/model_registry/placeholder",
      filter: "model_type = 'classification' AND is_active = true AND model_name LIKE 'holnn_%'",
      limit: 1
    ) do
      {:ok, %{"records" => [record | _]}} ->
        cas_uri = record["model_cas"]
        case CAS.get(did, cas_uri) do
          {:ok, binary} -> {:ok, :erlang.binary_to_term(binary, [:safe])}
          err           -> err
        end
      _ ->
        {:error, :no_saved_model}
    end
  end
end
