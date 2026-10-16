defmodule Przma.Search.Chunker do
  @moduledoc """
  Splits text into overlapping pieces ("chunks") of about `size` words.

  Each piece becomes one row (and one vector) in the user's search table.
  Small pieces keep search precise: a 300-page PDF becomes a few thousand
  pieces, and a question matches the one paragraph that answers it instead
  of "the whole PDF".

      Chunker.split(text)                       # ~200 words, 30 words overlap
      Chunker.split(text, size: 120, overlap: 20)

  The overlap means a sentence cut at a piece's end still appears whole at
  the start of the next piece.
  """

  @default_size 200
  @default_overlap 30

  @spec split(String.t(), keyword()) :: [String.t()]
  def split(text, opts \\ []) when is_binary(text) do
    size = Keyword.get(opts, :size, @default_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)
    step = max(size - overlap, 1)

    case String.split(text, ~r/\s+/u, trim: true) do
      [] -> []
      words -> windows(words, size, step, [])
    end
  end

  # Take `size` words, then move forward `step` words, until the end.
  defp windows(words, size, step, acc) do
    acc = [words |> Enum.take(size) |> Enum.join(" ") | acc]

    case Enum.drop(words, size) do
      [] -> Enum.reverse(acc)
      _more -> windows(Enum.drop(words, step), size, step, acc)
    end
  end
end
