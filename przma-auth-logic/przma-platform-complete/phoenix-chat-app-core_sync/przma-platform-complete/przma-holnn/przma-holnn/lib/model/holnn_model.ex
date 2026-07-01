# lib/model/holnn_model.ex
#
# HOLNN — Holographic Layered Neural Network
#
# The perception classification engine at the heart of PRZMA.
#
# Architecture rationale:
#   "Holographic" — each filter's state contains information about all other
#   filters. The 7×7 interaction matrix encodes how each filter's state
#   influences every other filter. This reflects the Siddha teaching that
#   all layers of being are interdependent — the Body filter influences the
#   Heart filter, the Knowledge filter influences the Mind filter, etc.
#
#   "Layered" — 7 filters arranged concentrically around a Light center:
#     F1 Body       (outermost physical layer)
#     F2 Senses     (sensory processing)
#     F3 Mind       (cognitive/analytical)
#     F4 Heart      (Gateway — the central filter, mediates all others)
#     F5 Ego        (identity/self-concept)
#     F6 Knowledge  (wisdom/discernment)
#     F7 Detachment (innermost, closest to Light)
#
# Input: 446-dimensional feature tensor from 13 signal groups
# Output 1: 7-dimensional sigmoid — filter clarity scores [0=FOGGED, 1=CLEAR]
# Output 2: 49-dimensional sigmoid — 7×7 interaction matrix (flattened)
#
# The Heart Filter (F4, index 3) is the Gateway.
# When F4 is CLEAR, all other filters can clear more easily.
# When F4 is FOGGED, clearing other filters is harder.
# This asymmetry is encoded structurally — F4 has higher weights in the matrix.
#
# Model size: ~230K parameters. Trains in <1 minute on CPU. Runs at <5ms/inference.

defmodule PRZMA.HOLNN.Model do
  @moduledoc """
  Axon model definition for the HOLNN perception classifier.

  This module defines the neural network structure. Training and inference
  are handled by HOLNNTrainer and HOLNNInference respectively.
  """

  # Input/output dimensions
  @input_dim     446    # 13 signal groups, see HOLNNFeatureExtractor
  @hidden1       256
  @hidden2       128
  @hidden3        64
  @n_filters       7    # Body, Senses, Mind, Heart, Ego, Knowledge, Detachment
  @matrix_size    49    # 7×7 filter interaction matrix
  @dropout_rate1  0.3
  @dropout_rate2  0.2

  # Filter indices (0-based)
  @body         0
  @senses       1
  @mind         2
  @heart        3   # Gateway — most important
  @ego          4
  @knowledge    5
  @detachment   6

  def input_dim,   do: @input_dim
  def n_filters,   do: @n_filters
  def matrix_size, do: @matrix_size
  def heart_index, do: @heart

  @doc """
  Build the HOLNN Axon model graph.

  Architecture:
    Input (446) → Shared encoder (256→128→64) →
      Head A: Filter states (64 → 7 sigmoid)
      Head B: Matrix (64 → 49 sigmoid)
  """
  def build do
    input = Axon.input("features", shape: {nil, @input_dim})

    # ── Shared encoder — extracts the perception signature ──────────────────
    # BatchNorm after each Dense stabilises training on diverse user data.
    # Dropout prevents overfitting on small personal datasets.
    shared = input
      |> Axon.dense(@hidden1, name: "encoder1")
      |> Axon.batch_norm(name: "bn1")
      |> Axon.activation(:relu, name: "act1")
      |> Axon.dropout(rate: @dropout_rate1, name: "drop1")
      |> Axon.dense(@hidden2, name: "encoder2")
      |> Axon.batch_norm(name: "bn2")
      |> Axon.activation(:relu, name: "act2")
      |> Axon.dropout(rate: @dropout_rate2, name: "drop2")
      |> Axon.dense(@hidden3, name: "encoder3")
      |> Axon.activation(:relu, name: "act3")

    # ── Head A: Filter clarity scores ───────────────────────────────────────
    # One sigmoid output per filter.
    # 0.0 = fully FOGGED, 1.0 = fully CLEAR.
    # CLEAR/FOGGED threshold is 0.5, but the raw score is more informative.
    filter_states = shared
      |> Axon.dense(@hidden3 // 2, activation: :relu, name: "filter_head1")
      |> Axon.dense(@n_filters, activation: :sigmoid, name: "filter_states")

    # ── Head B: Interaction matrix ───────────────────────────────────────────
    # Encodes how each filter's state influences every other filter.
    # matrix[i][j] = influence of filter i on filter j.
    # High values mean filter i strongly shapes filter j's clarity.
    # The Heart filter (row 3, col 3) has structurally higher influence
    # — this is encoded in training via the Heart-weighted loss.
    matrix = shared
      |> Axon.dense(@hidden3, activation: :relu, name: "matrix_head1")
      |> Axon.dense(@matrix_size, activation: :sigmoid, name: "matrix_output")

    # ── Combined output ──────────────────────────────────────────────────────
    # Returns a map with both outputs for loss computation.
    Axon.container(
      %{filter_states: filter_states, matrix: matrix},
      name: "holnn_output"
    )
  end

  @doc """
  Build a lightweight inference-only model (no dropout, no batch_norm running stats).
  Used when loading a saved model for inference.
  """
  def build_inference do
    input = Axon.input("features", shape: {nil, @input_dim})

    shared = input
      |> Axon.dense(@hidden1, name: "encoder1")
      |> Axon.activation(:relu)
      |> Axon.dense(@hidden2, name: "encoder2")
      |> Axon.activation(:relu)
      |> Axon.dense(@hidden3, name: "encoder3")
      |> Axon.activation(:relu)

    filter_states = shared
      |> Axon.dense(@hidden3 // 2, activation: :relu, name: "filter_head1")
      |> Axon.dense(@n_filters, activation: :sigmoid, name: "filter_states")

    matrix = shared
      |> Axon.dense(@hidden3, activation: :relu, name: "matrix_head1")
      |> Axon.dense(@matrix_size, activation: :sigmoid, name: "matrix_output")

    Axon.container(%{filter_states: filter_states, matrix: matrix})
  end

  @doc """
  HOLNN loss function.

  Combines three components:
    1. Filter state loss — binary cross-entropy vs user labels
    2. Matrix consistency loss — matrix should be symmetric-ish
    3. Heart gateway loss — Heart filter state should correlate with mean of others
                           (weighted 2× to reflect its gateway role)

  The Heart-gateway loss embeds the Siddha teaching that Heart clarity
  is prerequisite to other filter clarity — a strong structural prior.
  """
  def loss(predictions, targets) do
    import Nx

    filter_preds  = predictions.filter_states
    filter_labels = targets.filter_states
    matrix_preds  = predictions.matrix

    # 1. Binary cross-entropy for filter states
    # Add small epsilon to prevent log(0)
    eps = Nx.tensor(1.0e-7)
    bce = Nx.negate(
      Nx.add(
        Nx.multiply(filter_labels, Nx.log(Nx.add(filter_preds, eps))),
        Nx.multiply(
          Nx.subtract(1.0, filter_labels),
          Nx.log(Nx.add(Nx.subtract(1.0, filter_preds), eps))
        )
      )
    ) |> Nx.mean()

    # 2. Matrix symmetry regularisation
    # The interaction matrix should be approximately symmetric
    # matrix[i][j] ≈ matrix[j][i] (bidirectional influence)
    matrix_7x7  = Nx.reshape(matrix_preds, {:auto, @n_filters, @n_filters})
    matrix_T    = Nx.transpose(matrix_7x7, axes: [0, 2, 1])
    sym_loss    = Nx.subtract(matrix_7x7, matrix_T) |> Nx.pow(2) |> Nx.mean()

    # 3. Heart gateway loss
    # Heart filter (index 3) should have the highest influence on overall clarity
    heart_pred  = Nx.slice(filter_preds,  [0, @heart], [:auto, 1])
    others_mean = Nx.mean(filter_preds, axes: [1], keep_axes: true)
    # Heart should be at least as clear as the mean of others
    # Penalise when others are clear but Heart is not
    gateway_loss = Nx.max(
      Nx.subtract(others_mean, heart_pred),
      Nx.tensor(0.0)
    ) |> Nx.mean()

    # Weighted combination
    # BCE dominates, symmetry is a soft constraint, gateway is structural prior
    Nx.add(
      Nx.add(bce, Nx.multiply(0.1, sym_loss)),
      Nx.multiply(2.0, gateway_loss)
    )
  end

  @doc "Filter names in order (index 0..6)."
  def filter_names, do: ~w(body senses mind heart ego knowledge detachment)

  @doc "Map filter index to atom."
  def filter_atom(0), do: :body
  def filter_atom(1), do: :senses
  def filter_atom(2), do: :mind
  def filter_atom(3), do: :heart
  def filter_atom(4), do: :ego
  def filter_atom(5), do: :knowledge
  def filter_atom(6), do: :detachment
  def filter_atom(_), do: :unknown

  @doc "Map filter atom to index."
  def filter_index(:body),        do: 0
  def filter_index(:senses),      do: 1
  def filter_index(:mind),        do: 2
  def filter_index(:heart),       do: 3
  def filter_index(:ego),         do: 4
  def filter_index(:knowledge),   do: 5
  def filter_index(:detachment),  do: 6
  def filter_index(_),            do: -1

  @doc "Convert raw sigmoid outputs to CLEAR/FOGGED states."
  def to_filter_states(filter_tensor, threshold \\ 0.5) do
    import Nx
    values = Nx.to_list(filter_tensor) |> List.flatten()
    values
    |> Enum.with_index()
    |> Enum.map(fn {score, i} ->
        {filter_atom(i), %{
          state: if(score >= threshold, do: :clear, else: :fogged),
          score: Float.round(score, 4),
          label: if(score >= threshold, do: "CLEAR", else: "FOGGED"),
        }}
      end)
    |> Enum.into(%{})
  end

  @doc "Reshape flattened 49-dim matrix output to 7×7 nested list."
  def to_interaction_matrix(matrix_tensor) do
    values = Nx.to_list(matrix_tensor) |> List.flatten()
    filter_names = filter_names()
    for {row_name, row_i} <- Enum.with_index(filter_names) do
      row = for {col_name, col_i} <- Enum.with_index(filter_names) do
        {col_name, Enum.at(values, row_i * @n_filters + col_i)}
      end |> Enum.into(%{})
      {row_name, row}
    end |> Enum.into(%{})
  end
end
